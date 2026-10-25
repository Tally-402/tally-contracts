// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {TabManager} from "../src/TabManager.sol";

/// Sponsored lines (Tally for Networks): one sponsor deposit backs many agents.
contract SponsoredTest is BaseTest {
    address network = makeAddr("network");
    uint256 pkA = 0xA1;
    uint256 pkB = 0xB2;
    uint256 sponsorId;
    uint256 lineA;
    uint256 lineB;

    function setUp() public override {
        super.setUp();
        usdc.mint(network, 10_000 * USDC);
        vm.startPrank(network);
        usdc.approve(address(tabs), type(uint256).max);
        sponsorId = tabs.openSponsor();
        tabs.depositSponsorCollateral(sponsorId, 300 * USDC);
        lineA = tabs.openSponsoredLine(sponsorId, vm.addr(pkA), tabs.NO_CAP());
        lineB = tabs.openSponsoredLine(sponsorId, vm.addr(pkB), uint128(50 * USDC));
        uint64 until = uint64(vm.getBlockTimestamp() + 30 days);
        tabs.setMandate(lineA, uint128(1_000 * USDC), uint128(1_000 * USDC), until, bytes32(0));
        tabs.setMandate(lineB, uint128(1_000 * USDC), uint128(1_000 * USDC), until, bytes32(0));
        vm.stopPrank();
    }

    function _intentFor(uint256 id, uint256 amount, uint256 nonce, bool escrowed)
        internal
        view
        returns (TabManager.PaymentIntent memory p)
    {
        p = _intent(amount, nonce, escrowed);
        p.lineId = id;
        p.epoch = tabs.getLine(id).epoch;
    }

    function _payAs(uint256 pk, TabManager.PaymentIntent memory p) internal returns (uint256) {
        return tabs.pay(p, _sign(p, pk), new bytes32[](0));
    }

    function _sponsorOut() internal view returns (uint256) {
        return tabs.getSponsor(sponsorId).outstanding;
    }

    function test_OneDepositBacksManyAgents() public {
        _payAs(pkA, _intentFor(lineA, 200 * USDC, 1, false));
        _payAs(pkB, _intentFor(lineB, 40 * USDC, 1, false));
        assertEq(_sponsorOut(), 240 * USDC);
        assertEq(lens.availableCredit(lineA), 60 * USDC, "sponsor has 60 left");
        assertEq(lens.availableCredit(lineB), 10 * USDC, "line B's cap leaves 10");
        assertEq(pool.outstanding(), 240 * USDC);
    }

    function test_SharedLimitStopsTheNextAgent() public {
        _payAs(pkA, _intentFor(lineA, 280 * USDC, 1, false));
        TabManager.PaymentIntent memory p = _intentFor(lineB, 30 * USDC, 1, false);
        bytes memory sig = _sign(p, pkB);
        vm.expectRevert(abi.encodeWithSelector(TabManager.AboveCreditLimit.selector, 30 * USDC, 20 * USDC));
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_LineCapApplies() public {
        TabManager.PaymentIntent memory p = _intentFor(lineB, 51 * USDC, 1, false);
        bytes memory sig = _sign(p, pkB);
        vm.expectRevert(abi.encodeWithSelector(TabManager.AboveCreditLimit.selector, 51 * USDC, 50 * USDC));
        tabs.pay(p, sig, new bytes32[](0));
        vm.startPrank(network);
        tabs.setLineCap(lineB, tabs.NO_CAP());
        vm.stopPrank();
        _payAs(pkB, _intentFor(lineB, 51 * USDC, 2, false));
    }

    /// Review finding L-1: a cap of 0 freezes the line instead of removing the cap.
    function test_ZeroCapFreezesLine() public {
        vm.prank(network);
        tabs.setLineCap(lineA, 0);
        assertEq(lens.availableCredit(lineA), 0);
        TabManager.PaymentIntent memory p = _intentFor(lineA, 1, 1, false);
        bytes memory sig = _sign(p, pkA);
        vm.expectRevert(abi.encodeWithSelector(TabManager.AboveCreditLimit.selector, 1, 0));
        tabs.pay(p, sig, new bytes32[](0));
        _payAs(pkB, _intentFor(lineB, 10 * USDC, 1, false)); // other agents keep working
    }

    function test_RepayFreesSponsorCollateral() public {
        _payAs(pkA, _intentFor(lineA, 100 * USDC, 1, false));
        assertEq(tabs.sponsorFreeCollateral(sponsorId), 200 * USDC);
        vm.prank(network);
        vm.expectRevert(abi.encodeWithSelector(TabManager.CollateralLocked.selector, 201 * USDC, 200 * USDC));
        tabs.withdrawSponsorCollateral(sponsorId, 201 * USDC, network);
        vm.prank(network);
        tabs.repay(lineA, 100 * USDC);
        assertEq(_sponsorOut(), 0);
        vm.prank(network);
        tabs.withdrawSponsorCollateral(sponsorId, 300 * USDC, network);
        assertEq(tabs.getSponsor(sponsorId).collateral, 0);
    }

    function test_PastDueLineLiquidatesAgainstSponsor() public {
        _payAs(pkA, _intentFor(lineA, 100 * USDC, 1, false));
        _payAs(pkB, _intentFor(lineB, 20 * USDC, 1, false));
        vm.warp(vm.getBlockTimestamp() + 12 days + 1);
        (uint256 seized, uint256 loss) = tabs.liquidate(lineA);
        assertEq(seized, 100 * USDC);
        assertEq(loss, 0);
        assertEq(tabs.getSponsor(sponsorId).collateral, 200 * USDC);
        assertEq(_sponsorOut(), 20 * USDC, "line B still owes its own balance");
        assertEq(pool.outstanding(), 20 * USDC);
    }

    function test_EscrowRefundReducesSponsorBalance() public {
        uint256 hold = _payAs(pkA, _intentFor(lineA, 80 * USDC, 1, true));
        assertEq(_sponsorOut(), 80 * USDC);
        vm.prank(verifier);
        escrow.flag(hold, bytes32(0));
        vm.prank(arbiter);
        escrow.resolve(hold, true);
        assertEq(_sponsorOut(), 0);
        assertEq(pool.outstanding(), 0);
    }

    function test_EscrowReleaseKeepsSponsorBalance() public {
        uint256 hold = _payAs(pkA, _intentFor(lineA, 80 * USDC, 1, true));
        vm.prank(verifier);
        escrow.pass(hold);
        assertEq(_sponsorOut(), 80 * USDC, "held moved to billable, still owed");
    }

    function test_RevertWhen_OwnCollateralOnSponsoredLine() public {
        vm.prank(network);
        vm.expectRevert(TabManager.SponsoredLine.selector);
        tabs.depositCollateral(lineA, 1 * USDC);
    }

    function test_RevertWhen_OutsiderUsesSponsor() public {
        vm.startPrank(owner);
        vm.expectRevert(TabManager.NotSponsorOwner.selector);
        tabs.openSponsoredLine(sponsorId, owner, 1);
        vm.expectRevert(TabManager.NotSponsorOwner.selector);
        tabs.withdrawSponsorCollateral(sponsorId, 1, owner);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setMandate(lineA, 1, 1, uint64(vm.getBlockTimestamp() + 1 days), bytes32(0));
        vm.expectRevert(TabManager.NotSponsored.selector);
        tabs.setLineCap(lineId, 1);
        vm.stopPrank();
    }

    function test_OwnCollateralLinesUnaffected() public {
        _payAs(pkA, _intentFor(lineA, 300 * USDC, 1, false));
        _pay(_intent(100 * USDC, 1, false)); // the base line still uses its own 1,000 collateral
        assertEq(_outstanding(lineId), 100 * USDC);
        assertEq(lens.availableCredit(lineId), 900 * USDC);
    }

    function testFuzz_SponsorNeverOverLent(uint96 a, uint96 b) public {
        uint256 amtA = bound(a, 1, 400 * USDC);
        uint256 amtB = bound(b, 1, 400 * USDC);
        try this.payExternal(pkA, _intentFor(lineA, amtA, 1, false)) {} catch {}
        try this.payExternal(pkB, _intentFor(lineB, amtB, 1, false)) {} catch {}
        assertLe(_sponsorOut(), tabs.getSponsor(sponsorId).collateral);
        assertLe(_outstanding(lineB), 50 * USDC);
        assertEq(_sponsorOut(), _outstanding(lineA) + _outstanding(lineB));
    }

    function payExternal(uint256 pk, TabManager.PaymentIntent memory p) external returns (uint256) {
        return _payAs(pk, p);
    }
}
