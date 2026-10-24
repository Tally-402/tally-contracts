// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {Escrow} from "../src/Escrow.sol";
import {TabManager} from "../src/TabManager.sol";

contract EscrowTest is BaseTest {
    function _spent() internal view returns (uint128 s) {
        (,, s,,) = tabs.mandates(lineId);
    }

    function test_EscrowedPay_HoldsFunds() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        assertEq(id, 1);
        assertEq(usdc.balanceOf(address(escrow)), 80 * USDC);
        assertEq(usdc.balanceOf(seller), 0);
        assertEq(_outstanding(lineId), 80 * USDC);
    }

    function test_Pass_ReleasesToSellerMinusFee() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.pass(id);
        assertEq(usdc.balanceOf(seller), 79.2e6);
        assertEq(tabs.feesAccrued(), 0.4e6);
        assertEq(pool.idle(), 1_000_000 * USDC - 80 * USDC + 0.4e6, "lenders' share of the fee");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(_outstanding(lineId), 80 * USDC, "owner still owes the tab");
    }

    function test_Claim_AfterSilentReview() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.expectRevert(Escrow.ReviewOpen.selector);
        escrow.claim(id);
        vm.warp(block.timestamp + 1 days + 1);
        escrow.claim(id);
        assertEq(usdc.balanceOf(seller), 79.2e6);
    }

    function test_FlagThenRefund_PaysDownTabAndRestoresBudget() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.flag(id, keccak256("schema mismatch"));
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Flagged));
        escrow.claim(id);

        vm.prank(arbiter);
        escrow.resolve(id, true);
        assertEq(_outstanding(lineId), 0);
        assertEq(_dueAt(lineId), 0);
        assertEq(pool.outstanding(), 0);
        assertEq(pool.idle(), 1_000_000 * USDC);
        assertEq(_spent(), 0);
        assertEq(usdc.balanceOf(seller), 0);
        assertEq(tabs.feesAccrued(), 0, "no fee on refunded jobs");
    }

    function test_FlagThenRelease() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(id, false);
        assertEq(usdc.balanceOf(seller), 79.2e6);
    }

    function test_RevertWhen_FlagAfterWindow() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(verifier);
        vm.expectRevert(Escrow.ReviewClosed.selector);
        escrow.flag(id, bytes32(0));
    }

    function test_RevertWhen_OutsiderActs() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.expectRevert();
        escrow.pass(id);
        vm.expectRevert();
        escrow.resolve(id, true);
        vm.expectRevert(Escrow.OnlyManager.selector);
        escrow.open(lineId, seller, 1, 0, bytes32(0));
    }

    /// M-2: a disputed hold is never billed, so it cannot make the owner past due.
    function test_DisputedHold_NotBilledOrLiquidatable() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.warp(block.timestamp + 6 days);
        assertFalse(tabs.isPastDue(lineId));
        vm.expectRevert(TabManager.NotPastDue.selector);
        tabs.liquidate(lineId);
        (uint256 billed, uint256 unbilled, uint256 held,,) = tabs.statementOf(lineId);
        assertEq(billed + unbilled, 0);
        assertEq(held, 80 * USDC);
    }

    /// Liquidation seizes only billed spending; escrowed money settles through escrow.
    function test_Liquidation_LeavesHeldAlone_RefundRepaysPool() public {
        _pay(_intent(10 * USDC, 1, false));
        uint256 id = _pay(_intent(80 * USDC, 2, true));
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.warp(block.timestamp + 12 days + 1);
        (uint256 seized,) = tabs.liquidate(lineId);
        assertEq(seized, 10 * USDC);
        assertEq(_outstanding(lineId), 80 * USDC);
        vm.prank(arbiter);
        escrow.resolve(id, true);
        assertEq(_outstanding(lineId), 0);
        assertEq(pool.outstanding(), 0);
        assertEq(pool.idle(), 1_000_000 * USDC + 0.05e6, "lenders' share of the direct payment's fee");
    }

    /// Release makes the escrowed amount billable in the current cycle.
    function test_Release_BillsOwner() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.pass(id);
        (uint256 billed, uint256 unbilled, uint256 held,, uint256 cycleEnd) = tabs.statementOf(lineId);
        assertEq(held, 0);
        assertEq(unbilled, 80 * USDC);
        assertEq(billed, 0);
        assertEq(cycleEnd, block.timestamp + 7 days);
    }

    /// M-1: a seller that cannot receive USDC no longer locks funds; the arbiter refunds.
    function test_BlacklistedSeller_ArbiterRefunds() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        usdc.setBlacklisted(seller, true);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert();
        escrow.claim(id);
        vm.prank(arbiter);
        escrow.resolve(id, true);
        assertEq(_outstanding(lineId), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    /// L-3: a flagged hold with no ruling refunds after the ruling window.
    function test_FlaggedWithoutRuling_Expires() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.expectRevert(Escrow.RulingOpen.selector);
        escrow.expire(id);
        vm.warp(block.timestamp + 7 days + 1);
        escrow.expire(id);
        assertEq(_outstanding(lineId), 0);
    }

    /// M-3: refunding a hold from an old mandate does not reopen the new mandate's budget.
    function test_OldEpochRefund_DoesNotRestoreNewBudget() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(owner);
        tabs.setMandate(lineId, uint128(100 * USDC), uint128(100 * USDC), uint64(block.timestamp + 1 days), bytes32(0));
        _pay(_intent(100 * USDC, 2, false));
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(id, true);
        assertEq(_spent(), 100 * USDC, "new budget still fully spent");
        _payExpectRevert(_intent(1 * USDC, 3, false), abi.encodeWithSelector(TabManager.AboveBudget.selector));
    }

    /// Rotating the agent key keeps the mandate, so refunds still restore its budget.
    function test_AgentRotation_RefundStillRestoresBudget() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(owner);
        tabs.setAgent(lineId, agent);
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(id, true);
        assertEq(_spent(), 0);
    }

    /// Audit finding: an admin change to rulingWindow does not move an existing deadline.
    function test_RulingDeadline_FixedAtFlagTime() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.flag(id, bytes32(0));
        vm.prank(admin);
        escrow.setWindows(1 days, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Escrow.RulingOpen.selector);
        escrow.expire(id);
        vm.warp(block.timestamp + 5 days + 1);
        escrow.expire(id);
    }

    /// Audit lead: a blocked treasury no longer blocks escrow releases.
    function test_BlockedTreasury_DoesNotBlockRelease() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        usdc.setBlacklisted(treasury, true);
        vm.prank(verifier);
        escrow.pass(id);
        assertEq(usdc.balanceOf(seller), 79.2e6);
    }

    function test_RevertWhen_DoubleRelease() public {
        uint256 id = _pay(_intent(80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.pass(id);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Released));
        escrow.pass(id);
    }
}
