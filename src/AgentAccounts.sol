// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice The one ERC-8004 Identity Registry read this contract needs.
interface IAgentWallets {
    function getAgentWallet(uint256 agentId) external view returns (address);
}

/// @title AgentAccounts
/// @notice Prepaid accounts for agent owners. An owner deposits USDC once and sets a refill rule for
///         each of its agents ("keep this wallet between $5 and $20, at most $50 a day"). When an agent's
///         wallet drops below its floor, anyone (the agent itself, the owner, or a keeper) can call
///         `refill`, which tops it back up to the target from the owner's balance.
///
///         Only the owner can withdraw or change rules. A refill can only ever send USDC to a wallet the
///         owner registered, by the amount its rule allows, so a leaked agent key risks at most that
///         agent's daily cap. Tally holds no keys and has no admin role here.
///
///         Earn (opt-in): an owner can supply its balance above a cash buffer to one ERC-4626 USDC vault of
///         its choice (a Morpho vault, Aave's ERC-4626 wrapper, or Tally's CreditPool). Refills and withdrawals
///         pull from the vault when the cash runs short. No leverage. Each owner's vault shares are tracked
///         separately and every vault call is measured by what actually moved, so one owner's vault choice can
///         never touch another owner's money. Vault risk (smart contract, liquidity) is the owner's.
///
///         8004 binding: an agent added by its ERC-8004 id (`setAgentById`) is refilled only while the
///         registry still lists the same payment wallet for that id. If the agent changes hands or wallets,
///         refills stop until the owner approves the new wallet.
contract AgentAccounts is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Rule {
        uint128 floor; // refill when the agent's USDC balance is below this
        uint128 target; // ... back up to this
        uint128 dailyCap; // most this agent can receive per UTC day
        uint128 sentToday; // refills sent during `day`
        uint64 day; // day number (block.timestamp / 1 days) that `sentToday` belongs to
        bool active;
        uint256 boundId; // ERC-8004 agentId + 1 when added by id; 0 when added by address
    }

    IERC20 public immutable usdc;
    IAgentWallets public immutable identity; // ERC-8004 Identity Registry on this chain (zero = no binding)

    mapping(address owner => uint256) public balanceOf;
    mapping(address owner => bool) public paused;
    mapping(address owner => mapping(address agent => Rule)) public rules;

    // Earn
    mapping(address owner => IERC4626) public earnVault; // zero = off
    mapping(address owner => uint256) public earnShares; // vault shares held for this owner
    mapping(address owner => uint256) public earnBuffer; // cash kept liquid for refills

    event Deposited(address indexed owner, address indexed from, uint256 amount);
    event Withdrawn(address indexed owner, address indexed to, uint256 amount);
    event AgentSet(address indexed owner, address indexed agent, uint256 floor, uint256 target, uint256 dailyCap);
    event AgentRemoved(address indexed owner, address indexed agent);
    event PausedSet(address indexed owner, bool paused);
    event Refilled(address indexed owner, address indexed agent, uint256 amount, address caller);
    event AgentBound(address indexed owner, address indexed agent, uint256 indexed agentId);
    event EarnSet(address indexed owner, address indexed vault, uint256 buffer);
    event Supplied(address indexed owner, address indexed vault, uint256 assets, uint256 shares);
    event Unwound(address indexed owner, address indexed vault, uint256 assets, uint256 shares);

    error ZeroAmount();
    error ZeroAddress();
    error BadRule();
    error InsufficientBalance();
    error NotAgent();
    error AccountPaused();
    error NothingToRefill();
    error BadVault();
    error NoRegistry();
    error NoAgentWallet();
    error AgentWalletChanged();
    error VaultIlliquid();

    constructor(IERC20 usdc_, IAgentWallets identity_) {
        if (address(usdc_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
        identity = identity_;
    }

    // ------------------------------------------------------------------ money in and out

    /// @notice Add USDC to your own account.
    function deposit(uint256 amount) external {
        _deposit(msg.sender, amount);
    }

    /// @notice Add USDC to someone else's account (an on-ramp, a sponsor, a payroll run).
    function depositFor(address owner, uint256 amount) external {
        if (owner == address(0)) revert ZeroAddress();
        _deposit(owner, amount);
    }

    function _deposit(address owner, uint256 amount) internal nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = usdc.balanceOf(address(this)) - before; // credit what actually arrived
        balanceOf[owner] += got;
        emit Deposited(owner, msg.sender, got);
    }

    /// @notice Take USDC out of your account. Works while paused.
    function withdraw(uint256 amount, address to) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (amount > balanceOf[msg.sender]) _pull(msg.sender, amount - balanceOf[msg.sender]);
        uint256 bal = balanceOf[msg.sender];
        if (amount > bal) revert InsufficientBalance();
        balanceOf[msg.sender] = bal - amount;
        usdc.safeTransfer(to, amount);
        emit Withdrawn(msg.sender, to, amount);
    }

    // ------------------------------------------------------------------ rules

    /// @notice Register an agent wallet, or change its rule. Keeps today's refill count.
    function setAgent(address agent, uint128 floor, uint128 target, uint128 dailyCap) external {
        _setRule(agent, floor, target, dailyCap, 0);
    }

    /// @notice Add an agent by its ERC-8004 id: the rule applies to the id's current payment wallet, and
    ///         refills stop if the registry later points the id at a different wallet.
    function setAgentById(uint256 agentId, uint128 floor, uint128 target, uint128 dailyCap) external returns (address agent) {
        if (address(identity) == address(0)) revert NoRegistry();
        agent = identity.getAgentWallet(agentId);
        if (agent == address(0)) revert NoAgentWallet();
        _setRule(agent, floor, target, dailyCap, agentId + 1);
        emit AgentBound(msg.sender, agent, agentId);
    }

    function _setRule(address agent, uint128 floor, uint128 target, uint128 dailyCap, uint256 boundId) internal {
        if (agent == address(0)) revert ZeroAddress();
        if (target == 0 || floor > target || dailyCap == 0) revert BadRule();
        Rule storage r = rules[msg.sender][agent];
        (r.floor, r.target, r.dailyCap, r.active, r.boundId) = (floor, target, dailyCap, true, boundId);
        emit AgentSet(msg.sender, agent, floor, target, dailyCap);
    }

    /// @notice False when an agent added by 8004 id no longer matches the registry's payment wallet.
    function bindingOk(address owner, address agent) public view returns (bool) {
        uint256 b = rules[owner][agent].boundId;
        return b == 0 || identity.getAgentWallet(b - 1) == agent;
    }

    function removeAgent(address agent) external {
        if (!rules[msg.sender][agent].active) revert NotAgent();
        rules[msg.sender][agent].active = false;
        emit AgentRemoved(msg.sender, agent);
    }

    /// @notice Stop all refills from your account at once. Deposits and withdrawals still work.
    function setPaused(bool p) external {
        paused[msg.sender] = p;
        emit PausedSet(msg.sender, p);
    }

    // ------------------------------------------------------------------ refills

    /// @notice How much `refill(owner, agent)` would send right now (0 if nothing).
    function refillable(address owner, address agent) public view returns (uint256) {
        Rule storage r = rules[owner][agent];
        if (!r.active || paused[owner] || !bindingOk(owner, agent)) return 0;
        uint256 cash = usdc.balanceOf(agent);
        if (cash >= r.floor && cash != 0) return 0; // a floor of 0 means "refill only when empty"
        if (cash >= r.target) return 0;
        uint256 want = r.target - cash;
        uint64 today = uint64(block.timestamp / 1 days);
        uint256 sent = r.day == today ? r.sentToday : 0;
        uint256 left = r.dailyCap > sent ? r.dailyCap - sent : 0;
        uint256 bal = balanceOf[owner] + earnLiquid(owner);
        if (want > left) want = left;
        if (want > bal) want = bal;
        return want;
    }

    /// @notice Top `agent` back up to its target. Anyone can call; funds only go to the registered agent.
    function refill(address owner, address agent) external nonReentrant returns (uint256 amount) {
        Rule storage r = rules[owner][agent];
        if (!r.active) revert NotAgent();
        if (paused[owner]) revert AccountPaused();
        if (!bindingOk(owner, agent)) revert AgentWalletChanged();
        amount = refillable(owner, agent);
        if (amount == 0) revert NothingToRefill();
        uint64 today = uint64(block.timestamp / 1 days);
        if (r.day != today) (r.day, r.sentToday) = (today, 0);
        if (amount > balanceOf[owner]) {
            _pull(owner, amount - balanceOf[owner]);
            if (amount > balanceOf[owner]) amount = balanceOf[owner]; // the vault paid out a little less (rounding)
            if (amount == 0) revert NothingToRefill();
        }
        r.sentToday += uint128(amount);
        balanceOf[owner] -= amount;
        usdc.safeTransfer(agent, amount);
        emit Refilled(owner, agent, amount, msg.sender);
    }

    // ------------------------------------------------------------------ earn (opt-in)

    /// @notice Value of the owner's vault shares, in USDC.
    function earnValue(address owner) public view returns (uint256) {
        IERC4626 v = earnVault[owner];
        uint256 sh = earnShares[owner];
        return address(v) == address(0) || sh == 0 ? 0 : v.convertToAssets(sh);
    }

    /// @notice What could be pulled out of the vault for this owner right now.
    function earnLiquid(address owner) public view returns (uint256) {
        IERC4626 v = earnVault[owner];
        if (address(v) == address(0) || earnShares[owner] == 0) return 0;
        uint256 mine = v.convertToAssets(earnShares[owner]);
        uint256 vaultMax = v.maxWithdraw(address(this));
        return mine < vaultMax ? mine : vaultMax;
    }

    /// @notice Cash plus vault value.
    function totalOf(address owner) external view returns (uint256) {
        return balanceOf[owner] + earnValue(owner);
    }

    /// @notice Opt in to (or change) earning: supply cash above `buffer` to `vault`, an ERC-4626 vault for
    ///         this USDC. `vault` = address(0) turns earning off and brings everything back to cash.
    ///         Changing vaults unwinds the old position first (reverts if the old vault can't pay out in full).
    function setEarn(IERC4626 vault, uint256 buffer) external nonReentrant {
        if (address(vault) != address(0) && vault.asset() != address(usdc)) revert BadVault();
        IERC4626 old = earnVault[msg.sender];
        if (address(old) != address(0) && old != vault && earnShares[msg.sender] > 0) {
            uint256 sh = earnShares[msg.sender];
            uint256 redeemable = old.maxRedeem(address(this));
            _unwind(msg.sender, old, sh < redeemable ? sh : redeemable);
            if (earnShares[msg.sender] != 0) revert VaultIlliquid();
        }
        earnVault[msg.sender] = vault;
        earnBuffer[msg.sender] = buffer;
        emit EarnSet(msg.sender, address(vault), buffer);
        if (address(vault) != address(0)) _supplyExcess(msg.sender);
    }

    /// @notice Supply the owner's cash above its buffer to its vault. Anyone can call (a keeper after deposits).
    function sweep(address owner) external nonReentrant returns (uint256) {
        return _supplyExcess(owner);
    }

    function _supplyExcess(address owner) internal returns (uint256 assets) {
        IERC4626 v = earnVault[owner];
        if (address(v) == address(0)) return 0;
        uint256 cash = balanceOf[owner];
        uint256 buf = earnBuffer[owner];
        if (cash <= buf) return 0;
        assets = cash - buf;
        uint256 max = v.maxDeposit(address(this));
        if (assets > max) assets = max;
        if (assets == 0) return 0;
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = v.balanceOf(address(this));
        usdc.forceApprove(address(v), assets);
        v.deposit(assets, address(this));
        usdc.forceApprove(address(v), 0);
        uint256 spent = usdcBefore - usdc.balanceOf(address(this));
        uint256 got = v.balanceOf(address(this)) - sharesBefore;
        balanceOf[owner] -= spent;
        earnShares[owner] += got;
        emit Supplied(owner, address(v), spent, got);
    }

    /// @dev Bring `need` USDC (or as much as the vault can pay) back to the owner's cash.
    function _pull(address owner, uint256 need) internal {
        IERC4626 v = earnVault[owner];
        uint256 sh = earnShares[owner];
        if (address(v) == address(0) || sh == 0) return;
        uint256 liquid = earnLiquid(owner);
        if (liquid == 0) return;
        if (need >= liquid) {
            uint256 redeemable = v.maxRedeem(address(this));
            _unwind(owner, v, sh < redeemable ? sh : redeemable);
        } else {
            uint256 shares = v.previewWithdraw(need);
            _unwind(owner, v, shares < sh ? shares : sh);
        }
    }

    function _unwind(address owner, IERC4626 v, uint256 shares) internal {
        if (shares == 0) return;
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 sharesBefore = v.balanceOf(address(this));
        v.redeem(shares, address(this), address(this));
        uint256 got = usdc.balanceOf(address(this)) - usdcBefore;
        uint256 burned = sharesBefore - v.balanceOf(address(this));
        if (burned > earnShares[owner]) burned = earnShares[owner];
        earnShares[owner] -= burned;
        balanceOf[owner] += got;
        emit Unwound(owner, address(v), got, burned);
    }
}
