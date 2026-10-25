// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {TabManager} from "../src/TabManager.sol";

/// Sub-tabs, self-funding agents and vouching.
contract AgenticTest is BaseTest {
    function _intentOn(uint256 id, uint256 amount, uint256 nonce, address seller_)
        internal
        view
        returns (TabManager.PaymentIntent memory p)
    {
        p = _intent(amount, nonce, false);
        p.lineId = id;
        p.epoch = tabs.getLine(id).epoch;
        p.seller = seller_;
    }

    function _payAs(TabManager.PaymentIntent memory p, uint256 pk) internal {
        tabs.pay(p, _sign(p, pk), new bytes32[](0));
    }

    function _payAsExpectRevert(TabManager.PaymentIntent memory p, uint256 pk, bytes4 err) internal {
        bytes memory sig = _sign(p, pk);
        vm.expectRevert(err);
        tabs.pay(p, sig, new bytes32[](0));
    }

    // ================================================================ sub-tabs

    uint256 workerPk = 0xBEE;

    function test_SubTab_WorkerSpendsWithinItsCap() public {
        address worker = vm.addr(workerPk);
        vm.prank(agent); // the orchestrator itself hands out the budget
        tabs.setDelegate(lineId, worker, uint128(30 * USDC), uint64(vm.getBlockTimestamp() + 1 days));

        vm.expectEmit(true, true, false, true);
        emit TabManager.DelegatePaid(lineId, worker, 20 * USDC);
        _payAs(_intent(20 * USDC, 1, false), workerPk);
        assertEq(_outstanding(lineId), 20 * USDC, "rolls up into the line's tab");
        (, uint128 spent,,) = tabs.delegates(lineId, worker);
        assertEq(spent, 20 * USDC);

        _payAsExpectRevert(_intent(11 * USDC, 2, false), workerPk, TabManager.AboveDelegateCap.selector);
        _payAs(_intent(10 * USDC, 3, false), workerPk);

        // The orchestrator's own key still spends normally, outside the worker's cap.
        _pay(_intent(5 * USDC, 4, false));
        assertEq(_outstanding(lineId), 35 * USDC);
    }

    function test_SubTab_MandateStillApplies() public {
        address worker = vm.addr(workerPk);
        vm.prank(owner);
        tabs.setDelegate(lineId, worker, uint128(1_000 * USDC), uint64(vm.getBlockTimestamp() + 1 days));
        _payAsExpectRevert(_intent(101 * USDC, 1, false), workerPk, TabManager.AboveMaxPerPayment.selector);
    }

    function test_SubTab_ExpiresAndDiesOnMandateChange() public {
        address worker = vm.addr(workerPk);
        vm.prank(agent);
        tabs.setDelegate(lineId, worker, uint128(30 * USDC), uint64(vm.getBlockTimestamp() + 1 hours));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _payAsExpectRevert(_intent(1 * USDC, 1, false), workerPk, TabManager.DelegateInactive.selector);

        vm.prank(agent);
        tabs.setDelegate(lineId, worker, uint128(30 * USDC), uint64(vm.getBlockTimestamp() + 1 days));
        _payAs(_intent(1 * USDC, 2, false), workerPk);
        // The owner changes the mandate: every worker is cut off at once.
        vm.prank(owner);
        tabs.setMandate(
            lineId, uint128(100 * USDC), uint128(500 * USDC), uint64(vm.getBlockTimestamp() + 30 days), bytes32(0)
        );
        _payAsExpectRevert(_intent(1 * USDC, 3, false), workerPk, TabManager.DelegateInactive.selector);
    }

    function test_SubTab_RevokeAndStrangers() public {
        address worker = vm.addr(workerPk);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setDelegate(lineId, worker, uint128(30 * USDC), uint64(vm.getBlockTimestamp() + 1 days));

        _payAsExpectRevert(_intent(1 * USDC, 1, false), workerPk, TabManager.BadSignature.selector);

        vm.prank(agent);
        tabs.setDelegate(lineId, worker, uint128(30 * USDC), uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(agent);
        tabs.setDelegate(lineId, worker, 0, 0); // revoke
        _payAsExpectRevert(_intent(1 * USDC, 2, false), workerPk, TabManager.BadSignature.selector);
    }

    // ================================================================ self-funding

    uint256 sellerAgentPk = 0x5E11;
    uint256 earnerLine;
    address earner;

    /// A second agent that sells to the first and owes on its own line.
    function _earnerWithDebt(uint256 debt) internal {
        earner = vm.addr(sellerAgentPk);
        address earnerOwner = makeAddr("earnerOwner");
        usdc.mint(earnerOwner, 1_000 * USDC);
        vm.startPrank(earnerOwner);
        usdc.approve(address(tabs), type(uint256).max);
        earnerLine = tabs.openLine(earner);
        tabs.depositCollateral(earnerLine, 500 * USDC);
        tabs.setMandate(
            earnerLine, uint128(100 * USDC), uint128(500 * USDC), uint64(vm.getBlockTimestamp() + 30 days), bytes32(0)
        );
        tabs.setSweep(earnerLine, earner, 5_000); // half of every payout repays its tab
        vm.stopPrank();
        if (debt > 0) _payAs(_intentOn(earnerLine, debt, 900, seller), sellerAgentPk);
    }

    function test_SelfFunding_EarningsRepayTheEarnersTab() public {
        _earnerWithDebt(30 * USDC);
        uint256 poolOut = pool.outstanding();

        vm.expectEmit(true, true, false, true);
        emit TabManager.AutoRepaid(earnerLine, earner, 49.5e6 / 2);
        _pay(_intentOn(lineId, 50 * USDC, 1, earner)); // the first agent buys from the earner

        assertEq(_outstanding(earnerLine), 30 * USDC - 24.75e6, "half the 49.50 payout repaid the tab");
        assertEq(usdc.balanceOf(earner), 24.75e6, "the earner keeps the other half");
        assertEq(pool.outstanding(), poolOut + 50 * USDC - 24.75e6, "the pool got the repayment");
    }

    function test_SelfFunding_NeverTakesMoreThanIsOwed() public {
        _earnerWithDebt(5 * USDC);
        _pay(_intentOn(lineId, 50 * USDC, 1, earner));
        assertEq(_outstanding(earnerLine), 0);
        assertEq(usdc.balanceOf(earner), 49.5e6 - 5 * USDC);
    }

    function test_SelfFunding_OnlyForTheLinesOwnKeys() public {
        _earnerWithDebt(0);
        vm.prank(tabs.getLine(earnerLine).owner);
        vm.expectRevert(TabManager.BadParams.selector);
        tabs.setSweep(earnerLine, makeAddr("someoneElse"), 5_000);
    }

    function test_SelfFunding_StopsWhenTheAgentKeyRotates() public {
        _earnerWithDebt(30 * USDC);
        vm.prank(tabs.getLine(earnerLine).owner);
        tabs.setAgent(earnerLine, makeAddr("newKey"));
        _pay(_intentOn(lineId, 50 * USDC, 1, earner));
        assertEq(_outstanding(earnerLine), 30 * USDC, "stale sweep is ignored");
        assertEq(usdc.balanceOf(earner), 49.5e6);
    }

    // ================================================================ vouching

    address voucher = makeAddr("voucher"); // an established agent's wallet
    address newcomer = makeAddr("newcomerOwner");
    uint256 newcomerPk = 0xC0DE;
    uint256 sponsorId;
    uint256 vouched;

    function _vouch(uint128 cap) internal {
        usdc.mint(voucher, 1_000 * USDC);
        vm.startPrank(voucher);
        usdc.approve(address(tabs), type(uint256).max);
        sponsorId = tabs.openSponsor();
        tabs.depositSponsorCollateral(sponsorId, 200 * USDC);
        vouched = tabs.openSponsoredLine(sponsorId, vm.addr(newcomerPk), cap);
        tabs.setManager(vouched, newcomer);
        vm.stopPrank();
        vm.prank(newcomer);
        tabs.acceptManager(vouched);
    }

    function test_Vouch_NewcomerRunsTheLine_VoucherEarns() public {
        _vouch(uint128(100 * USDC));
        vm.prank(newcomer);
        tabs.setMandate(
            vouched, uint128(50 * USDC), uint128(100 * USDC), uint64(vm.getBlockTimestamp() + 30 days), bytes32(0)
        );

        uint256 treasuryBefore = tabs.feesAccrued();
        _payAs(_intentOn(vouched, 40 * USDC, 1, seller), newcomerPk);
        // Fee 0.40: half to lenders, the treasury's 0.20 split with the voucher.
        assertEq(tabs.voucherFees(voucher), 0.1e6);
        assertEq(tabs.feesAccrued() - treasuryBefore, 0.1e6);

        vm.prank(voucher);
        tabs.claimVoucherFees(voucher);
        assertEq(usdc.balanceOf(voucher), 800 * USDC + 0.1e6);
    }

    function test_Vouch_ManagerCannotTouchTheStakeOrCap() public {
        _vouch(uint128(100 * USDC));
        uint128 noCap = tabs.NO_CAP();
        vm.startPrank(newcomer);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setLineCap(vouched, noCap);
        vm.expectRevert(TabManager.NotSponsorOwner.selector);
        tabs.withdrawSponsorCollateral(sponsorId, 1, newcomer);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setManager(vouched, makeAddr("other"));
        vm.stopPrank();
    }

    function test_Vouch_DefaultHitsTheVouchersStake() public {
        _vouch(uint128(100 * USDC));
        vm.prank(newcomer);
        tabs.setMandate(
            vouched, uint128(50 * USDC), uint128(100 * USDC), uint64(vm.getBlockTimestamp() + 30 days), bytes32(0)
        );
        _payAs(_intentOn(vouched, 40 * USDC, 1, seller), newcomerPk);
        vm.warp(vm.getBlockTimestamp() + 13 days); // past due and grace
        (uint256 seized, uint256 loss) = tabs.liquidate(vouched);
        assertEq(seized, 40 * USDC);
        assertEq(loss, 0);
        assertEq(tabs.getSponsor(sponsorId).collateral, 160 * USDC, "the voucher pays for the newcomer's default");
    }

    function test_Vouch_VoucherCanFreezeAndRemoveTheManager() public {
        _vouch(uint128(100 * USDC));
        vm.prank(newcomer);
        tabs.setMandate(
            vouched, uint128(50 * USDC), uint128(100 * USDC), uint64(vm.getBlockTimestamp() + 30 days), bytes32(0)
        );
        vm.prank(voucher);
        tabs.setLineCap(vouched, 0);
        TabManager.PaymentIntent memory p = _intentOn(vouched, 1 * USDC, 1, seller);
        bytes memory sig = _sign(p, newcomerPk);
        vm.expectRevert(abi.encodeWithSelector(TabManager.AboveCreditLimit.selector, 1 * USDC, 0));
        tabs.pay(p, sig, new bytes32[](0));

        vm.prank(voucher);
        tabs.setManager(vouched, address(0));
        vm.prank(newcomer);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setMandate(vouched, 1, 1, 1, bytes32(0));
    }

    function test_Vouch_ManagerMustAccept_AndOnlyForSponsoredLines() public {
        vm.prank(owner);
        vm.expectRevert(TabManager.NotSponsored.selector);
        tabs.setManager(lineId, newcomer);
        _vouch(uint128(100 * USDC));
        vm.prank(makeAddr("random"));
        vm.expectRevert(TabManager.NotManager.selector);
        tabs.acceptManager(vouched);
    }

    function test_NoVoucherCutOnOrdinaryLines() public {
        uint256 before = tabs.feesAccrued();
        _pay(_intent(40 * USDC, 1, false));
        assertEq(tabs.feesAccrued() - before, 0.2e6);
        assertEq(tabs.voucherFeesTotal(), 0);
    }
}
