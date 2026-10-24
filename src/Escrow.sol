// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ITabManager} from "./interfaces/ITally.sol";

/// @title Escrow
/// @notice Holds pool-funded payments for larger jobs until delivery is checked.
///
///         Held    -> pass (verifier), or review window lapses and anyone claims  -> Released
///         Held    -> flag (verifier, inside the review window)                    -> Flagged
///         Held    -> resolve (arbiter; e.g. the seller cannot receive funds)       -> Refunded | Released
///         Flagged -> resolve (arbiter)                                             -> Refunded | Released
///         Flagged -> no ruling by the deadline fixed at flag time, anyone expires it -> Refunded
///
///         The verifier can only pass or flag; it never chooses where funds go.
///         In v0 the arbiter is a Tally multisig; staked juror panels replace it later.
contract Escrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");

    enum Status {
        None,
        Held,
        Flagged,
        Released,
        Refunded
    }

    struct Hold {
        uint256 lineId;
        address seller;
        uint64 reviewEndsAt;
        uint64 rulingEndsAt;
        Status status;
        uint128 amount;
        uint128 fee;
        bytes32 resource;
    }

    IERC20 public immutable usdc;
    ITabManager public immutable manager;

    uint64 public reviewWindow = 1 days;
    uint64 public rulingWindow = 7 days;
    uint256 public nextHoldId = 1;
    mapping(uint256 => Hold) public holds;

    event Opened(uint256 indexed holdId, uint256 indexed lineId, address indexed seller, uint256 amount, bytes32 resource);
    event Flagged(uint256 indexed holdId, bytes32 reasonHash);
    event Released(uint256 indexed holdId, address indexed seller, uint256 net, uint256 fee);
    event Refunded(uint256 indexed holdId, uint256 indexed lineId, uint256 amount);
    event WindowsSet(uint64 reviewWindow, uint64 rulingWindow);

    error OnlyManager();
    error WrongStatus(Status status);
    error ReviewOpen();
    error ReviewClosed();
    error RulingOpen();
    error BadParams();

    constructor(IERC20 usdc_, ITabManager manager_, address admin) {
        usdc = usdc_;
        manager = manager_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Record a hold. The pool has already moved `amount` USDC here.
    function open(uint256 lineId, address seller, uint256 amount, uint256 fee, bytes32 resource)
        external
        returns (uint256 holdId)
    {
        if (msg.sender != address(manager)) revert OnlyManager();
        holdId = nextHoldId++;
        holds[holdId] = Hold({
            lineId: lineId,
            seller: seller,
            reviewEndsAt: SafeCast.toUint64(block.timestamp + reviewWindow),
            rulingEndsAt: 0,
            status: Status.Held,
            amount: SafeCast.toUint128(amount),
            fee: SafeCast.toUint128(fee),
            resource: resource
        });
        emit Opened(holdId, lineId, seller, amount, resource);
    }

    /// @notice Verifier confirms delivery; seller is paid.
    function pass(uint256 holdId) external nonReentrant onlyRole(VERIFIER_ROLE) {
        Hold storage h = holds[holdId];
        if (h.status != Status.Held) revert WrongStatus(h.status);
        _release(holdId, h);
    }

    /// @notice Verifier disputes delivery inside the review window.
    function flag(uint256 holdId, bytes32 reasonHash) external onlyRole(VERIFIER_ROLE) {
        Hold storage h = holds[holdId];
        if (h.status != Status.Held) revert WrongStatus(h.status);
        if (block.timestamp > h.reviewEndsAt) revert ReviewClosed();
        h.status = Status.Flagged;
        h.rulingEndsAt = SafeCast.toUint64(block.timestamp + rulingWindow);
        emit Flagged(holdId, reasonHash);
    }

    /// @notice If nobody flagged the job in time, anyone can release it to the seller.
    function claim(uint256 holdId) external nonReentrant {
        Hold storage h = holds[holdId];
        if (h.status != Status.Held) revert WrongStatus(h.status);
        if (block.timestamp <= h.reviewEndsAt) revert ReviewOpen();
        _release(holdId, h);
    }

    /// @notice Arbiter rules on a hold. Works on flagged holds, and on held ones that cannot settle
    ///         normally (for example, the seller's address can no longer receive USDC).
    function resolve(uint256 holdId, bool refund) external nonReentrant onlyRole(ARBITER_ROLE) {
        Hold storage h = holds[holdId];
        if (h.status != Status.Flagged && h.status != Status.Held) revert WrongStatus(h.status);
        if (refund) _refund(holdId, h);
        else _release(holdId, h);
    }

    /// @notice A flagged hold with no ruling after the ruling window refunds the buyer. Callable by anyone.
    function expire(uint256 holdId) external nonReentrant {
        Hold storage h = holds[holdId];
        if (h.status != Status.Flagged) revert WrongStatus(h.status);
        if (block.timestamp <= h.rulingEndsAt) revert RulingOpen();
        _refund(holdId, h);
    }

    function _release(uint256 holdId, Hold storage h) internal {
        h.status = Status.Released;
        uint256 amount = h.amount;
        uint256 fee = h.fee;
        usdc.safeTransfer(h.seller, amount - fee);
        if (fee > 0) usdc.safeTransfer(address(manager), fee);
        manager.onRelease(h.lineId, holdId, amount, fee);
        emit Released(holdId, h.seller, amount - fee, fee);
    }

    function _refund(uint256 holdId, Hold storage h) internal {
        h.status = Status.Refunded;
        uint256 amount = h.amount;
        usdc.safeTransfer(address(manager), amount);
        manager.creditRefund(h.lineId, holdId, amount);
        emit Refunded(holdId, h.lineId, amount);
    }

    function setWindows(uint64 reviewWindow_, uint64 rulingWindow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (reviewWindow_ < 1 hours || reviewWindow_ > 7 days) revert BadParams();
        if (rulingWindow_ < 1 days || rulingWindow_ > 30 days) revert BadParams();
        reviewWindow = reviewWindow_;
        rulingWindow = rulingWindow_;
        emit WindowsSet(reviewWindow_, rulingWindow_);
    }
}
