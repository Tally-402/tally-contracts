// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {TabManager} from "../src/TabManager.sol";
import {Escrow} from "../src/Escrow.sol";
import {ITabManager} from "../src/interfaces/ITally.sol";

/// Regression tests for the IMD swarm audit of 2026-10-24 (contracts/audits/2026-10-24-imd-swarm.md).
/// ScoreRegistry findings 1 and 2 are covered in ScoreRegistry.t.sol.
contract AuditImdTest is BaseTest {
    // ---------------------------------------------------------------- finding 3

    /// Intents pre-signed for the next counter values must not survive a mandate change.
    function test_F3_PreSignedFutureEpochsAreStale() public {
        uint32 e0 = tabs.getLine(lineId).epoch;
        TabManager.PaymentIntent[3] memory guesses;
        for (uint32 i = 0; i < 3; i++) {
            guesses[i] = _intent(50 * USDC, 100 + i, false);
            guesses[i].epoch = e0 + i + 1;
            guesses[i].deadline = block.timestamp + 365 days;
        }
        vm.startPrank(owner);
        tabs.revokeMandate(lineId);
        vm.prevrandao(bytes32(uint256(42)));
        tabs.setMandate(lineId, uint128(100 * USDC), uint128(500 * USDC), uint64(block.timestamp + 30 days), bytes32(0));
        vm.stopPrank();
        for (uint256 i = 0; i < 3; i++) {
            _payExpectRevert(guesses[i], abi.encodeWithSelector(TabManager.StaleEpoch.selector));
        }
        assertEq(_outstanding(lineId), 0);
        // A freshly signed intent for the new epoch still works.
        _pay(_intent(50 * USDC, 200, false));
        assertEq(_outstanding(lineId), 50 * USDC);
    }

    function test_F3_EpochDependsOnBlockRandomness() public {
        uint256 snap = vm.snapshotState();
        vm.prevrandao(bytes32(uint256(1)));
        vm.prank(owner);
        tabs.revokeMandate(lineId);
        uint32 a = tabs.getLine(lineId).epoch;
        vm.revertToState(snap);
        vm.prevrandao(bytes32(uint256(2)));
        vm.prank(owner);
        tabs.revokeMandate(lineId);
        assertTrue(tabs.getLine(lineId).epoch != a, "next epoch is not predictable from on-chain state alone");
    }

    // ---------------------------------------------------------------- finding 4

    /// A statement keeps the grace in force when its cycle opened, whatever setParams does later.
    function test_F4_IssuedStatementKeepsItsGrace() public {
        uint256 t0 = block.timestamp;
        _pay(_intent(100 * USDC, 1, false));
        vm.warp(t0 + 10 days + 1); // due at t0+10d, grace to t0+12d
        vm.expectRevert(TabManager.NotPastDue.selector);
        tabs.liquidate(lineId);

        vm.prank(admin);
        tabs.setParams(10_000, 100, 7 days, 3 days, 0);
        vm.expectRevert(TabManager.NotPastDue.selector);
        tabs.liquidate(lineId);
        assertFalse(tabs.isPastDue(lineId));
        assertEq(_collateral(lineId), 1_000 * USDC);

        vm.warp(t0 + 12 days + 1);
        assertTrue(tabs.isPastDue(lineId));
        (uint256 seized,) = tabs.liquidate(lineId);
        assertEq(seized, 100 * USDC);
    }

    /// The terms are fixed when the cycle opens, even if the cycle closes before anyone rolls it.
    function test_F4_ParamsChangedAfterCycleCloseDontRetime() public {
        uint256 t0 = block.timestamp;
        _pay(_intent(100 * USDC, 1, false));
        vm.warp(t0 + 7 days + 1); // cycle closed, not rolled yet
        vm.prank(admin);
        tabs.setParams(10_000, 100, 7 days, 1 days, 0);
        (,,, uint256 dueAt,) = tabs.statementOf(lineId);
        assertEq(dueAt, t0 + 10 days, "payment window from when the cycle opened");
        vm.warp(t0 + 11 days);
        vm.expectRevert(TabManager.NotPastDue.selector);
        tabs.liquidate(lineId);
    }

    // ---------------------------------------------------------------- finding 5

    /// A deposit made just before a payment and redeemed just after earns nothing.
    function test_F5_FeeSandwichEarnsNothing() public {
        address searcher = makeAddr("searcher");
        usdc.mint(searcher, 1_000_000 * USDC);
        vm.startPrank(searcher);
        usdc.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(1_000_000 * USDC, searcher);
        vm.stopPrank();

        _pay(_intent(100 * USDC, 1, false)); // 1 USDC fee, 0.5 to lenders

        vm.prank(searcher);
        uint256 out = pool.redeem(shares, searcher, searcher);
        assertLe(out, 1_000_000 * USDC, "no same-block yield");

        // Long-term lenders get the fee once it unlocks.
        uint256 before = pool.convertToAssets(pool.balanceOf(lp));
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(
            pool.convertToAssets(pool.balanceOf(lp)), before + 0.5e6, 1, "the LP gets the whole lender fee"
        );
    }

    function test_F5_YieldUnlocksLinearly() public {
        _pay(_intent(100 * USDC, 1, false));
        assertEq(pool.unvestedYield(), 0.5e6);
        vm.warp(block.timestamp + 12 hours);
        assertEq(pool.unvestedYield(), 0.25e6);
        vm.warp(block.timestamp + 12 hours);
        assertEq(pool.unvestedYield(), 0);
    }

    function test_F5_OnlyManagerAddsYield() public {
        vm.expectRevert();
        pool.addYield(1);
    }

    // ---------------------------------------------------------------- finding 6

    function test_F6_DepositToSomeoneElsesLineReverts() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        uint256 stolenId = tabs.openLine(attacker); // front-runs the victim's openLine
        vm.prank(owner);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.depositCollateral(stolenId, 500 * USDC);
    }

    function test_F6_DepositToSomeoneElsesSponsorReverts() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        uint256 sid = tabs.openSponsor();
        vm.prank(owner);
        vm.expectRevert(TabManager.NotSponsorOwner.selector);
        tabs.depositSponsorCollateral(sid, 500 * USDC);
    }

    // ---------------------------------------------------------------- finding 7

    function test_F7_DustPaymentReverts() public {
        // At 1% rounded up, a 1-unit payment would be all fee.
        _payExpectRevert(_intent(1, 1, false), abi.encodeWithSelector(TabManager.AmountTooSmall.selector));
        _pay(_intent(2, 2, false));
        assertEq(usdc.balanceOf(seller), 1, "the seller always receives something");
    }

    // ---------------------------------------------------------------- finding 8

    function test_F8_ZeroAdminRejected() public {
        vm.expectRevert(CreditPool.ZeroAddress.selector);
        new CreditPool(usdc, address(0), 0);
        vm.expectRevert(TabManager.ZeroAddress.selector);
        new TabManager(usdc, pool, address(0), treasury);
        vm.expectRevert(Escrow.ZeroAddress.selector);
        new Escrow(usdc, ITabManager(address(tabs)), address(0));
        vm.expectRevert(Escrow.ZeroAddress.selector);
        new Escrow(usdc, ITabManager(address(0)), admin);
    }

    function test_F8_SetEscrowChecksWiring() public {
        TabManager fresh = new TabManager(usdc, pool, admin, treasury);
        Escrow wrong = new Escrow(usdc, ITabManager(address(tabs)), admin); // wired to another manager
        vm.prank(admin);
        vm.expectRevert(TabManager.EscrowMismatch.selector);
        fresh.setEscrow(address(wrong));
        Escrow right = new Escrow(usdc, ITabManager(address(fresh)), admin);
        vm.prank(admin);
        fresh.setEscrow(address(right));
        assertEq(fresh.escrow(), address(right));
    }
}
