// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CreditPool
/// @notice USDC vault that funds agent tabs. Depositors receive tpUSDC shares (ERC-4626).
///         Lent-out principal stays on the books as `outstanding`, so share value does not
///         drop when the pool pays a seller; it only drops if a loss is realized.
contract CreditPool is ERC4626, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Principal currently lent out through the TabManager.
    uint256 public outstanding;
    /// @notice Maximum total assets the pool accepts. Zero means no cap.
    uint256 public depositCap;
    /// @notice Maximum share of total assets that may be lent out, in bps. Keeps a withdrawal buffer.
    uint16 public maxUtilizationBps = 9_000;
    uint16 public constant BPS = 10_000;

    event Funded(address indexed to, uint256 amount);
    event RepaymentRecorded(uint256 principal);
    event LossRealized(uint256 principal);
    event DepositCapSet(uint256 cap);
    event MaxUtilizationSet(uint16 bps);

    error InsufficientIdle(uint256 requested, uint256 idle);
    error ExceedsOutstanding(uint256 amount, uint256 outstanding);
    error UtilizationCap(uint256 lentAfter, uint256 maxLent);
    error BadParams();

    constructor(IERC20 usdc, address admin, uint256 cap)
        ERC20("Tally Pool USDC", "tpUSDC")
        ERC4626(usdc)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    // ---------------------------------------------------------------- accounting

    /// @notice USDC held by the pool and not lent out.
    function idle() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function totalAssets() public view override returns (uint256) {
        return idle() + outstanding;
    }

    /// @dev Virtual share offset protects early depositors against donation/inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------- limits

    function maxDeposit(address) public view override returns (uint256) {
        if (depositCap == 0) return type(uint256).max;
        uint256 assets = totalAssets();
        return assets >= depositCap ? 0 : depositCap - assets;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    /// @notice Withdrawals are limited to idle cash; lent-out principal returns as tabs are repaid.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), idle());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(idle(), Math.Rounding.Floor));
    }

    // ---------------------------------------------------------------- manager hooks

    /// @notice Send pool cash out against a tab. Only the TabManager can call this.
    function fund(address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        uint256 cash = idle();
        if (amount > cash) revert InsufficientIdle(amount, cash);
        uint256 maxLent = (totalAssets() * maxUtilizationBps) / BPS;
        if (outstanding + amount > maxLent) revert UtilizationCap(outstanding + amount, maxLent);
        outstanding += amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit Funded(to, amount);
    }

    /// @notice Record principal returned. The caller must have transferred the USDC in first.
    function recordRepayment(uint256 principal) external onlyRole(MANAGER_ROLE) {
        if (principal > outstanding) revert ExceedsOutstanding(principal, outstanding);
        outstanding -= principal;
        emit RepaymentRecorded(principal);
    }

    /// @notice Write off principal that will not come back. Lowers share value.
    function realizeLoss(uint256 principal) external onlyRole(MANAGER_ROLE) {
        if (principal > outstanding) revert ExceedsOutstanding(principal, outstanding);
        outstanding -= principal;
        emit LossRealized(principal);
    }

    // ---------------------------------------------------------------- admin

    function setMaxUtilization(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps == 0 || bps > BPS) revert BadParams();
        maxUtilizationBps = bps;
        emit MaxUtilizationSet(bps);
    }

    function setDepositCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositCap = cap;
        emit DepositCapSet(cap);
    }
}
