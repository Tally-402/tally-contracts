// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CreditPool} from "./CreditPool.sol";
import {IEscrow} from "./interfaces/ITally.sol";

/// @title TabManager
/// @notice Secured credit lines ("tabs") for AI agents paying over x402.
///
///         An owner opens a line, posts USDC collateral and sets a mandate (budget, per-payment cap,
///         allowed sellers, expiry). The owner's agent signs EIP-712 payment intents; anyone (normally
///         the Tally facilitator) submits them. The pool pays the seller at once, or into escrow for
///         larger jobs.
///
///         Billing works like a card statement. Spending accrues in a cycle (`billingPeriod`). When the
///         cycle closes, that spending becomes the statement, due `paymentWindow` later. A statement
///         unpaid `gracePeriod` after its due date can be liquidated against collateral. Escrowed amounts
///         are not billed until escrow releases them to the seller.
///
///         v0 is fully secured: total balance <= collateral (maxLtvBps <= 100%).
///
///         Sponsored lines (Tally for Networks): a sponsor, such as an agent network, deposits collateral once
///         and opens a line per agent. Each line keeps its own mandate, statements and record, with an optional
///         per-line cap; together they can never owe more than the sponsor's collateral allows. A past-due
///         sponsored line is liquidated against the sponsor's collateral.
contract TabManager is EIP712, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    struct Line {
        address owner;
        uint32 epoch; // bumps on mandate or agent change; invalidates older signed intents
        address agent;
        uint64 cycleEnd; // end of the open billing cycle, 0 if none open
        uint128 collateral;
        uint128 held; // escrowed, not yet billable
        uint128 unbilled; // spent in the open cycle
        uint128 billed; // statement balance
        uint64 statementDue; // due date of the statement balance, 0 if none
    }

    struct Sponsor {
        address owner;
        uint128 collateral;
        uint128 outstanding; // sum of outstandingOf() over the sponsor's lines
    }

    struct Mandate {
        uint128 maxPerPayment;
        uint128 budget;
        uint128 spent;
        uint64 validUntil;
        bytes32 sellersRoot; // 0 = any seller
    }

    struct PaymentIntent {
        uint256 lineId;
        uint32 epoch;
        address seller;
        uint256 amount;
        bytes32 resource; // hash of the x402 resource / request being paid for
        bool escrowed;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(uint256 lineId,uint32 epoch,address seller,uint256 amount,bytes32 resource,bool escrowed,uint256 nonce,uint256 deadline)"
    );

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_SELLER_FEE_BPS = 500;

    // ---------------------------------------------------------------- state

    IERC20 public immutable usdc;
    CreditPool public immutable pool;
    address public escrow;
    address public treasury;

    uint16 public maxLtvBps = BPS;
    uint16 public sellerFeeBps = 100;
    /// @notice Share of each seller fee paid to the pool as lender yield, in bps of the fee.
    ///         Raises the value of every tpUSDC share, so lenders earn from the cash they lend.
    uint16 public poolFeeShareBps = 5_000;
    uint32 public billingPeriod = 7 days;
    uint32 public paymentWindow = 3 days;
    uint32 public gracePeriod = 2 days;

    uint256 public nextLineId = 1;
    mapping(uint256 => Line) internal _lines;
    mapping(uint256 => Mandate) public mandates;
    mapping(uint256 => mapping(uint256 => bool)) public nonceUsed;
    /// @notice Mandate version per line; bumps on setMandate / revokeMandate.
    mapping(uint256 => uint32) public mandateVersion;
    /// @notice Mandate version at the time each escrow hold was opened.
    mapping(uint256 => uint32) public holdMandateVersion;
    /// @notice Treasury fees held here until swept (pull-based, so a blocked treasury blocks nothing else).
    uint256 public feesAccrued;

    uint256 public nextSponsorId = 1;
    mapping(uint256 => Sponsor) internal _sponsors;
    /// @notice Sponsor backing each line, 0 for a line secured by its own collateral.
    mapping(uint256 => uint256) public sponsorOf;
    /// @notice Cap on a sponsored line's outstanding balance. NO_CAP = only the sponsor's limit applies;
    ///         0 freezes the line (no new spending).
    mapping(uint256 => uint128) public lineCap;
    uint128 public constant NO_CAP = type(uint128).max;

    // ---------------------------------------------------------------- events

    event LineOpened(uint256 indexed lineId, address indexed owner, address indexed agent);
    event AgentSet(uint256 indexed lineId, address indexed agent, uint32 epoch);
    event CollateralDeposited(uint256 indexed lineId, address indexed from, uint256 amount);
    event CollateralWithdrawn(uint256 indexed lineId, address indexed to, uint256 amount);
    event MandateSet(
        uint256 indexed lineId,
        uint32 indexed epoch,
        uint128 maxPerPayment,
        uint128 budget,
        uint64 validUntil,
        bytes32 sellersRoot
    );
    event MandateRevoked(uint256 indexed lineId, uint32 epoch);
    event NonceCancelled(uint256 indexed lineId, uint256 nonce);
    event Paid(
        uint256 indexed lineId,
        address indexed seller,
        uint256 amount,
        uint256 fee,
        bytes32 resource,
        uint256 nonce,
        uint256 escrowHoldId
    );
    event Billed(uint256 indexed lineId, uint256 amount, uint64 cycleEnd);
    event Repaid(uint256 indexed lineId, address indexed from, uint256 amount);
    event RefundCredited(uint256 indexed lineId, uint256 indexed holdId, uint256 amount);
    event FeeDistributed(uint256 toPool, uint256 toTreasury);
    event FeesSwept(address indexed treasury, uint256 amount);
    event Liquidated(uint256 indexed lineId, uint256 seized, uint256 loss);
    event ParamsSet(
        uint16 maxLtvBps, uint16 sellerFeeBps, uint32 billingPeriod, uint32 paymentWindow, uint32 gracePeriod
    );
    event PoolFeeShareSet(uint16 bps);
    event TreasurySet(address treasury);
    event EscrowSet(address escrow);
    event SponsorOpened(uint256 indexed sponsorId, address indexed owner);
    event SponsorCollateralDeposited(uint256 indexed sponsorId, address indexed from, uint256 amount);
    event SponsorCollateralWithdrawn(uint256 indexed sponsorId, address indexed to, uint256 amount);
    event SponsoredLineOpened(uint256 indexed sponsorId, uint256 indexed lineId, address indexed agent, uint128 cap);
    event LineCapSet(uint256 indexed lineId, uint128 cap);

    // ---------------------------------------------------------------- errors

    error NotLineOwner();
    error UnknownLine();
    error ZeroAddress();
    error ZeroAmount();
    error IntentExpired();
    error NonceUsed();
    error StaleEpoch();
    error BadSignature();
    error BadSeller();
    error MandateInactive();
    error AboveMaxPerPayment();
    error AboveBudget();
    error SellerNotAllowed();
    error AboveCreditLimit(uint256 requested, uint256 available);
    error PastDue();
    error NotPastDue();
    error CollateralLocked(uint256 requested, uint256 free);
    error EscrowNotSet();
    error EscrowAlreadySet();
    error OnlyEscrow();
    error BadParams();
    error RefundExceedsHeld();
    error UnknownSponsor();
    error NotSponsorOwner();
    error NotSponsored();
    error SponsoredLine();

    // ---------------------------------------------------------------- setup

    constructor(IERC20 usdc_, CreditPool pool_, address admin, address treasury_) EIP712("Tally TabManager", "1") {
        if (address(usdc_) == address(0) || address(pool_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = usdc_;
        pool = pool_;
        treasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit TreasurySet(treasury_);
    }

    modifier onlyLineOwner(uint256 lineId) {
        address o = _lines[lineId].owner;
        if (o == address(0)) revert UnknownLine();
        if (o != msg.sender) revert NotLineOwner();
        _;
    }

    modifier onlySponsorOwner(uint256 sponsorId) {
        address o = _sponsors[sponsorId].owner;
        if (o == address(0)) revert UnknownSponsor();
        if (o != msg.sender) revert NotSponsorOwner();
        _;
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert OnlyEscrow();
        _;
    }

    // ---------------------------------------------------------------- owner actions

    function openLine(address agent) external returns (uint256 lineId) {
        if (agent == address(0)) revert ZeroAddress();
        lineId = nextLineId++;
        _lines[lineId].owner = msg.sender;
        _lines[lineId].agent = agent;
        emit LineOpened(lineId, msg.sender, agent);
    }

    /// @notice Rotate the agent key. Invalidates all intents signed before.
    function setAgent(uint256 lineId, address agent) external onlyLineOwner(lineId) {
        if (agent == address(0)) revert ZeroAddress();
        Line storage l = _lines[lineId];
        l.agent = agent;
        emit AgentSet(lineId, agent, ++l.epoch);
    }

    function depositCollateral(uint256 lineId, uint256 amount) external nonReentrant {
        if (_lines[lineId].owner == address(0)) revert UnknownLine();
        if (sponsorOf[lineId] != 0) revert SponsoredLine();
        if (amount == 0) revert ZeroAmount();
        _lines[lineId].collateral += SafeCast.toUint128(amount);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(lineId, msg.sender, amount);
    }

    function withdrawCollateral(uint256 lineId, uint256 amount, address to)
        external
        nonReentrant
        onlyLineOwner(lineId)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 free = freeCollateral(lineId);
        if (amount > free) revert CollateralLocked(amount, free);
        _lines[lineId].collateral -= SafeCast.toUint128(amount);
        usdc.safeTransfer(to, amount);
        emit CollateralWithdrawn(lineId, to, amount);
    }

    /// @notice Replace the mandate. Resets the budget counter and invalidates older signed intents.
    function setMandate(uint256 lineId, uint128 maxPerPayment, uint128 budget, uint64 validUntil, bytes32 sellersRoot)
        external
        onlyLineOwner(lineId)
    {
        uint32 e = ++_lines[lineId].epoch;
        ++mandateVersion[lineId];
        mandates[lineId] = Mandate(maxPerPayment, budget, 0, validUntil, sellersRoot);
        emit MandateSet(lineId, e, maxPerPayment, budget, validUntil, sellersRoot);
    }

    function revokeMandate(uint256 lineId) external onlyLineOwner(lineId) {
        uint32 e = ++_lines[lineId].epoch;
        ++mandateVersion[lineId];
        delete mandates[lineId];
        emit MandateRevoked(lineId, e);
    }

    /// @notice Cancel a single signed intent before anyone submits it.
    function cancelNonce(uint256 lineId, uint256 nonce) external onlyLineOwner(lineId) {
        nonceUsed[lineId][nonce] = true;
        emit NonceCancelled(lineId, nonce);
    }

    // ---------------------------------------------------------------- sponsors (Tally for Networks)

    /// @notice Open a sponsor account. The caller owns it and every line opened under it.
    function openSponsor() external returns (uint256 sponsorId) {
        sponsorId = nextSponsorId++;
        _sponsors[sponsorId].owner = msg.sender;
        emit SponsorOpened(sponsorId, msg.sender);
    }

    function depositSponsorCollateral(uint256 sponsorId, uint256 amount) external nonReentrant {
        if (_sponsors[sponsorId].owner == address(0)) revert UnknownSponsor();
        if (amount == 0) revert ZeroAmount();
        _sponsors[sponsorId].collateral += SafeCast.toUint128(amount);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit SponsorCollateralDeposited(sponsorId, msg.sender, amount);
    }

    function withdrawSponsorCollateral(uint256 sponsorId, uint256 amount, address to)
        external
        nonReentrant
        onlySponsorOwner(sponsorId)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 free = sponsorFreeCollateral(sponsorId);
        if (amount > free) revert CollateralLocked(amount, free);
        _sponsors[sponsorId].collateral -= SafeCast.toUint128(amount);
        usdc.safeTransfer(to, amount);
        emit SponsorCollateralWithdrawn(sponsorId, to, amount);
    }

    /// @notice Open a line for `agent` backed by the sponsor's collateral. The sponsor owner owns the line,
    ///         so it sets the line's mandate and can rotate its agent like any other line.
    /// @param cap Cap on this line's outstanding balance: NO_CAP for none, 0 to open it frozen.
    function openSponsoredLine(uint256 sponsorId, address agent, uint128 cap)
        external
        onlySponsorOwner(sponsorId)
        returns (uint256 lineId)
    {
        if (agent == address(0)) revert ZeroAddress();
        lineId = nextLineId++;
        _lines[lineId].owner = msg.sender;
        _lines[lineId].agent = agent;
        sponsorOf[lineId] = sponsorId;
        lineCap[lineId] = cap;
        emit LineOpened(lineId, msg.sender, agent);
        emit SponsoredLineOpened(sponsorId, lineId, agent, cap);
    }

    /// @notice Change a sponsored line's cap. NO_CAP removes it; 0 freezes the line. Lowering it below the
    ///         current balance only blocks new spending.
    function setLineCap(uint256 lineId, uint128 cap) external onlyLineOwner(lineId) {
        if (sponsorOf[lineId] == 0) revert NotSponsored();
        lineCap[lineId] = cap;
        emit LineCapSet(lineId, cap);
    }

    /// @dev Keep each sponsor's running total in step with its lines' balances.
    function _sponsorAdd(uint256 lineId, uint256 amount) internal {
        uint256 sid = sponsorOf[lineId];
        if (sid != 0) _sponsors[sid].outstanding += SafeCast.toUint128(amount);
    }

    function _sponsorSub(uint256 lineId, uint256 amount) internal {
        uint256 sid = sponsorOf[lineId];
        if (sid != 0) _sponsors[sid].outstanding -= SafeCast.toUint128(amount);
    }

    // ---------------------------------------------------------------- payments

    /// @notice Pay a seller from the pool against the line, authorized by the agent's signature.
    /// @param proof Merkle proof that `p.seller` is in the mandate's seller list (empty if any seller).
    function pay(PaymentIntent calldata p, bytes calldata signature, bytes32[] calldata proof)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 holdId)
    {
        Line storage l = _lines[p.lineId];
        if (l.owner == address(0)) revert UnknownLine();
        if (p.amount == 0) revert ZeroAmount();
        _checkSeller(p.seller);
        if (block.timestamp > p.deadline) revert IntentExpired();
        if (p.epoch != l.epoch) revert StaleEpoch();
        if (nonceUsed[p.lineId][p.nonce]) revert NonceUsed();
        if (!SignatureChecker.isValidSignatureNow(l.agent, hashIntent(p), signature)) revert BadSignature();

        _checkMandate(p.lineId, p.seller, p.amount, proof);
        _roll(l);
        _checkCredit(p.lineId, l, p.amount);
        _sponsorAdd(p.lineId, p.amount);

        nonceUsed[p.lineId][p.nonce] = true;
        mandates[p.lineId].spent += SafeCast.toUint128(p.amount);

        uint256 fee = Math.mulDiv(p.amount, sellerFeeBps, BPS, Math.Rounding.Ceil);

        if (p.escrowed) {
            address e = escrow;
            if (e == address(0)) revert EscrowNotSet();
            l.held += SafeCast.toUint128(p.amount);
            pool.fund(e, p.amount);
            holdId = IEscrow(e).open(p.lineId, p.seller, p.amount, fee, p.resource);
            holdMandateVersion[holdId] = mandateVersion[p.lineId];
        } else {
            _bill(p.lineId, l, p.amount);
            pool.fund(address(this), p.amount);
            usdc.safeTransfer(p.seller, p.amount - fee);
            _distributeFee(fee);
        }

        emit Paid(p.lineId, p.seller, p.amount, fee, p.resource, p.nonce, holdId);
    }

    function _checkSeller(address seller) internal view {
        if (
            seller == address(0) || seller == address(this) || seller == escrow || seller == address(pool)
                || seller == treasury
        ) revert BadSeller();
    }

    function _checkMandate(uint256 lineId, address seller, uint256 amount, bytes32[] calldata proof) internal view {
        Mandate storage m = mandates[lineId];
        if (m.validUntil < block.timestamp) revert MandateInactive();
        if (amount > m.maxPerPayment) revert AboveMaxPerPayment();
        if (uint256(m.spent) + amount > m.budget) revert AboveBudget();
        if (m.sellersRoot != bytes32(0)) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(seller))));
            if (!MerkleProof.verifyCalldata(proof, m.sellersRoot, leaf)) revert SellerNotAllowed();
        }
    }

    function _checkCredit(uint256 lineId, Line storage l, uint256 amount) internal view {
        if (l.billed > 0 && block.timestamp > l.statementDue) revert PastDue();
        uint256 avail = _available(lineId, l);
        if (amount > avail) revert AboveCreditLimit(amount, avail);
    }

    /// @dev Own-collateral line: its collateral times LTV, minus its balance. Sponsored line: the sponsor's
    ///      remaining limit, further capped by the line's own cap if set.
    function _available(uint256 lineId, Line storage l) internal view returns (uint256) {
        uint256 out = _outstanding(l);
        uint256 sid = sponsorOf[lineId];
        if (sid == 0) {
            uint256 limit = (uint256(l.collateral) * maxLtvBps) / BPS;
            return limit > out ? limit - out : 0;
        }
        Sponsor storage s = _sponsors[sid];
        uint256 sLimit = (uint256(s.collateral) * maxLtvBps) / BPS;
        uint256 avail = sLimit > s.outstanding ? sLimit - s.outstanding : 0;
        uint256 cap = lineCap[lineId];
        if (cap != NO_CAP) {
            uint256 capAvail = cap > out ? cap - out : 0;
            if (capAvail < avail) avail = capAvail;
        }
        return avail;
    }

    // ---------------------------------------------------------------- billing cycle

    /// @dev Close the open cycle if its end has passed: its spending becomes the statement.
    function _roll(Line storage l) internal {
        if (l.cycleEnd != 0 && block.timestamp >= l.cycleEnd) {
            if (l.unbilled > 0) {
                l.billed += l.unbilled;
                l.unbilled = 0;
                // An older unpaid statement keeps its earlier due date.
                if (l.statementDue == 0) l.statementDue = l.cycleEnd + paymentWindow;
            }
            l.cycleEnd = 0;
        }
    }

    /// @dev Add a billable amount to the open cycle, opening one if needed.
    function _bill(uint256 lineId, Line storage l, uint256 amount) internal {
        _roll(l);
        if (l.cycleEnd == 0) l.cycleEnd = SafeCast.toUint64(block.timestamp + billingPeriod);
        l.unbilled += SafeCast.toUint128(amount);
        emit Billed(lineId, amount, l.cycleEnd);
    }

    // ---------------------------------------------------------------- escrow hooks

    /// @notice Escrow paid the seller and sent the fee here: the held amount becomes billable.
    function onRelease(uint256 lineId, uint256, uint256 amount, uint256 fee) external onlyEscrow {
        Line storage l = _lines[lineId];
        l.held -= SafeCast.toUint128(amount);
        _bill(lineId, l, amount);
        _distributeFee(fee);
    }

    /// @dev Pool share goes to the pool at once (raises share value); the rest waits for sweepFees.
    function _distributeFee(uint256 fee) internal {
        if (fee == 0) return;
        uint256 toPool = (fee * poolFeeShareBps) / BPS;
        uint256 toTreasury = fee - toPool;
        if (toPool > 0) usdc.safeTransfer(address(pool), toPool);
        feesAccrued += toTreasury;
        emit FeeDistributed(toPool, toTreasury);
    }

    /// @notice Send accrued treasury fees to the treasury. Callable by anyone.
    function sweepFees() external nonReentrant returns (uint256 amount) {
        amount = feesAccrued;
        if (amount == 0) revert ZeroAmount();
        feesAccrued = 0;
        usdc.safeTransfer(treasury, amount);
        emit FeesSwept(treasury, amount);
    }

    /// @notice Escrow sent a refunded hold back here; it pays the pool back in full.
    function creditRefund(uint256 lineId, uint256 holdId, uint256 amount) external nonReentrant onlyEscrow {
        Line storage l = _lines[lineId];
        // held always includes every open hold: liquidation never touches it.
        if (amount > l.held) revert RefundExceedsHeld();
        l.held -= SafeCast.toUint128(amount);
        _sponsorSub(lineId, amount);
        usdc.safeTransfer(address(pool), amount);
        pool.recordRepayment(amount);
        // Only restore budget to the mandate the hold was spent under.
        if (holdMandateVersion[holdId] == mandateVersion[lineId]) {
            Mandate storage m = mandates[lineId];
            m.spent = m.spent > amount ? m.spent - SafeCast.toUint128(amount) : 0;
        }
        emit RefundCredited(lineId, holdId, amount);
    }

    // ---------------------------------------------------------------- repayment

    /// @notice Repay billable balance (statement first, then the open cycle). Anyone may repay.
    ///         Escrowed amounts are not repayable until released.
    function repay(uint256 lineId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Line storage l = _lines[lineId];
        if (l.owner == address(0)) revert UnknownLine();
        _roll(l);
        paid = Math.min(amount, uint256(l.billed) + l.unbilled);
        if (paid == 0) revert ZeroAmount();

        uint256 fromBilled = Math.min(paid, l.billed);
        l.billed -= SafeCast.toUint128(fromBilled);
        l.unbilled -= SafeCast.toUint128(paid - fromBilled);
        if (l.billed == 0) l.statementDue = 0;
        _sponsorSub(lineId, paid);

        usdc.safeTransferFrom(msg.sender, address(pool), paid);
        pool.recordRepayment(paid);
        emit Repaid(lineId, msg.sender, paid);
    }

    // ---------------------------------------------------------------- default

    /// @notice Seize collateral to cover billable balance once a statement is past due plus grace.
    ///         Seizes the open cycle too (the whole billable balance accelerates on default).
    ///         Escrowed amounts stay on the line and settle through escrow.
    function liquidate(uint256 lineId) external nonReentrant returns (uint256 seized, uint256 loss) {
        Line storage l = _lines[lineId];
        _roll(l);
        if (!(l.billed > 0 && block.timestamp > uint256(l.statementDue) + gracePeriod)) revert NotPastDue();

        uint256 owed = uint256(l.billed) + l.unbilled;
        uint256 sid = sponsorOf[lineId];
        if (sid == 0) {
            seized = Math.min(owed, l.collateral);
            l.collateral -= SafeCast.toUint128(seized);
        } else {
            // A sponsored line is secured by the sponsor's collateral.
            Sponsor storage sp = _sponsors[sid];
            seized = Math.min(owed, sp.collateral);
            sp.collateral -= SafeCast.toUint128(seized);
            sp.outstanding -= SafeCast.toUint128(owed);
        }
        loss = owed - seized;

        l.billed = 0;
        l.unbilled = 0;
        l.statementDue = 0;
        l.cycleEnd = 0;

        if (seized > 0) {
            usdc.safeTransfer(address(pool), seized);
            pool.recordRepayment(seized);
        }
        if (loss > 0) pool.realizeLoss(loss);
        emit Liquidated(lineId, seized, loss);
    }

    // ---------------------------------------------------------------- views

    function hashIntent(PaymentIntent calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_INTENT_TYPEHASH,
                    p.lineId,
                    p.epoch,
                    p.seller,
                    p.amount,
                    p.resource,
                    p.escrowed,
                    p.nonce,
                    p.deadline
                )
            )
        );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getLine(uint256 lineId) external view returns (Line memory) {
        return _lines[lineId];
    }

    function _outstanding(Line storage l) internal view returns (uint256) {
        return uint256(l.held) + l.unbilled + l.billed;
    }

    /// @notice Everything the pool has lent against this line (billed + unbilled + held in escrow).
    function outstandingOf(uint256 lineId) public view returns (uint256) {
        return _outstanding(_lines[lineId]);
    }

    /// @notice The line's statement as it stands now, including a cycle that has closed but not rolled.
    function statementOf(uint256 lineId)
        public
        view
        returns (uint256 billed, uint256 unbilled, uint256 held, uint256 dueAt, uint256 cycleEnd)
    {
        Line storage l = _lines[lineId];
        billed = l.billed;
        unbilled = l.unbilled;
        held = l.held;
        dueAt = l.statementDue;
        cycleEnd = l.cycleEnd;
        if (cycleEnd != 0 && block.timestamp >= cycleEnd) {
            if (unbilled > 0) {
                billed += unbilled;
                unbilled = 0;
                if (dueAt == 0) dueAt = cycleEnd + paymentWindow;
            }
            cycleEnd = 0;
        }
    }

    function isPastDue(uint256 lineId) external view returns (bool) {
        (uint256 billed,,, uint256 dueAt,) = statementOf(lineId);
        return billed > 0 && block.timestamp > dueAt + gracePeriod;
    }

    /// @notice Most the line could owe right now: own collateral times LTV, or for a sponsored line the
    ///         sponsor's limit (shared with its other lines) capped by the line's own cap.
    function creditLimit(uint256 lineId) public view returns (uint256) {
        uint256 sid = sponsorOf[lineId];
        if (sid == 0) return (uint256(_lines[lineId].collateral) * maxLtvBps) / BPS;
        uint256 limit = (uint256(_sponsors[sid].collateral) * maxLtvBps) / BPS;
        uint256 cap = lineCap[lineId];
        return cap < limit ? cap : limit;
    }

    /// @notice What the line can spend now. For sponsored lines this accounts for the sponsor's other lines.
    function availableCredit(uint256 lineId) external view returns (uint256) {
        return _available(lineId, _lines[lineId]);
    }

    function getSponsor(uint256 sponsorId) external view returns (Sponsor memory) {
        return _sponsors[sponsorId];
    }

    /// @notice Sponsor collateral not needed to secure its lines' balances.
    function sponsorFreeCollateral(uint256 sponsorId) public view returns (uint256) {
        Sponsor storage sp = _sponsors[sponsorId];
        uint256 needed = Math.mulDiv(sp.outstanding, BPS, maxLtvBps, Math.Rounding.Ceil);
        return sp.collateral > needed ? sp.collateral - needed : 0;
    }

    /// @notice Collateral not needed to secure the current balance.
    function freeCollateral(uint256 lineId) public view returns (uint256) {
        Line storage l = _lines[lineId];
        uint256 needed = Math.mulDiv(_outstanding(l), BPS, maxLtvBps, Math.Rounding.Ceil);
        return l.collateral > needed ? l.collateral - needed : 0;
    }

    // ---------------------------------------------------------------- admin

    /// @notice v0 is secured only: maxLtvBps must stay at or below 100%.
    function setParams(
        uint16 maxLtvBps_,
        uint16 sellerFeeBps_,
        uint32 billingPeriod_,
        uint32 paymentWindow_,
        uint32 gracePeriod_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxLtvBps_ == 0 || maxLtvBps_ > BPS || sellerFeeBps_ > MAX_SELLER_FEE_BPS) {
            revert BadParams();
        }
        if (billingPeriod_ < 1 days || billingPeriod_ > 31 days) revert BadParams();
        if (paymentWindow_ < 1 days || paymentWindow_ > 14 days || gracePeriod_ > 14 days) revert BadParams();
        // A statement must settle or liquidate before the next one closes, so due dates never merge early.
        if (uint256(billingPeriod_) < uint256(paymentWindow_) + gracePeriod_) revert BadParams();
        maxLtvBps = maxLtvBps_;
        sellerFeeBps = sellerFeeBps_;
        billingPeriod = billingPeriod_;
        paymentWindow = paymentWindow_;
        gracePeriod = gracePeriod_;
        emit ParamsSet(maxLtvBps_, sellerFeeBps_, billingPeriod_, paymentWindow_, gracePeriod_);
    }

    function setPoolFeeShare(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > BPS) revert BadParams();
        poolFeeShareBps = bps;
        emit PoolFeeShareSet(bps);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice One-time wiring of the Escrow contract.
    function setEscrow(address escrow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (escrow != address(0)) revert EscrowAlreadySet();
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        emit EscrowSet(escrow_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
