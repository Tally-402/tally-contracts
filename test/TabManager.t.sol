// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {TabManager} from "../src/TabManager.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockSmartWallet} from "./mocks/Mocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract TabManagerTest is BaseTest {
    // ------------------------------------------------------------ paying

    function test_PayDirect_PaysSellerAndBooksTab() public {
        uint256 assetsBefore = pool.totalAssets();
        _pay(_intent(40 * USDC, 1, false));

        assertEq(usdc.balanceOf(seller), 39.6e6, "seller gets amount minus 1% fee");
        assertEq(tabs.feesAccrued(), 0.2e6, "half the fee waits for the treasury");
        assertEq(_outstanding(lineId), 40 * USDC);
        assertEq(pool.outstanding(), 40 * USDC);
        assertEq(pool.totalAssets(), assetsBefore, "fee income is locked at first");
        assertEq(pool.unvestedYield(), 0.2e6, "lenders' half of the fee is locked");
        assertEq(_cycleEnd(lineId), vm.getBlockTimestamp() + 7 days, "opens a weekly cycle");
        assertEq(_dueAt(lineId), 0, "nothing is due until the cycle closes");
        assertEq(lens.availableCredit(lineId), 960 * USDC);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(pool.totalAssets(), assetsBefore + 0.2e6, "lenders earn half the fee once it unlocks");
    }

    function test_Pay_ByAnySubmitter() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, agentPk);
        vm.prank(makeAddr("facilitator"));
        tabs.pay(p, sig, new bytes32[](0));
        assertEq(_outstanding(lineId), 10 * USDC);
    }

    function test_RevertWhen_SignedByWrongKey() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, 0xBAD);
        vm.expectRevert(TabManager.BadSignature.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_RevertWhen_IntentTampered() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, agentPk);
        p.amount = 90 * USDC;
        vm.expectRevert(TabManager.BadSignature.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_RevertWhen_NonceReused() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 7, false);
        bytes memory sig = _sign(p, agentPk);
        tabs.pay(p, sig, new bytes32[](0));
        vm.expectRevert(TabManager.NonceUsed.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_RevertWhen_IntentExpired() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, agentPk);
        vm.warp(p.deadline + 1);
        vm.expectRevert(TabManager.IntentExpired.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_RevertWhen_AboveMaxPerPayment() public {
        _payExpectRevert(_intent(101 * USDC, 1, false), abi.encodeWithSelector(TabManager.AboveMaxPerPayment.selector));
    }

    function test_RevertWhen_AboveBudget() public {
        for (uint256 i = 1; i <= 5; i++) {
            _pay(_intent(100 * USDC, i, false));
        }
        _payExpectRevert(_intent(1, 6, false), abi.encodeWithSelector(TabManager.AboveBudget.selector));
    }

    function test_RevertWhen_MandateExpiredOrRevoked() public {
        vm.warp(vm.getBlockTimestamp() + 31 days);
        _payExpectRevert(_intent(1 * USDC, 1, false), abi.encodeWithSelector(TabManager.MandateInactive.selector));

        vm.startPrank(owner);
        tabs.setMandate(
            lineId, uint128(100 * USDC), uint128(500 * USDC), uint64(vm.getBlockTimestamp() + 1 days), bytes32(0)
        );
        tabs.revokeMandate(lineId);
        vm.stopPrank();
        _payExpectRevert(_intent(1 * USDC, 2, false), abi.encodeWithSelector(TabManager.MandateInactive.selector));
    }

    function test_RevertWhen_AboveCreditLimit() public {
        vm.prank(owner);
        tabs.setMandate(
            lineId, uint128(5_000 * USDC), uint128(5_000 * USDC), uint64(vm.getBlockTimestamp() + 1 days), bytes32(0)
        );
        _payExpectRevert(
            _intent(1_001 * USDC, 1, false),
            abi.encodeWithSelector(TabManager.AboveCreditLimit.selector, 1_001 * USDC, 1_000 * USDC)
        );
    }

    function test_SellerAllowlist() public {
        address other = makeAddr("otherSeller");
        bytes32 a = keccak256(bytes.concat(keccak256(abi.encode(seller))));
        bytes32 b = keccak256(bytes.concat(keccak256(abi.encode(other))));
        bytes32 root = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        vm.prank(owner);
        tabs.setMandate(lineId, uint128(100 * USDC), uint128(500 * USDC), uint64(vm.getBlockTimestamp() + 1 days), root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        tabs.pay(p, _sign(p, agentPk), proof);
        assertEq(_outstanding(lineId), 10 * USDC);

        TabManager.PaymentIntent memory q = _intent(10 * USDC, 2, false);
        q.seller = makeAddr("stranger");
        bytes memory sig = _sign(q, agentPk);
        vm.expectRevert(TabManager.SellerNotAllowed.selector);
        tabs.pay(q, sig, proof);
    }

    function test_SmartWalletAgent_ERC1271() public {
        uint256 signerPk = 0x5EC;
        MockSmartWallet wallet = new MockSmartWallet(vm.addr(signerPk));
        vm.prank(owner);
        tabs.setAgent(lineId, address(wallet));
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        tabs.pay(p, _sign(p, signerPk), new bytes32[](0));
        assertEq(_outstanding(lineId), 10 * USDC);
    }

    function test_RevertWhen_Paused() public {
        vm.prank(admin);
        tabs.pause();
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, agentPk);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    // ------------------------------------------------------------ repaying

    function test_Repay_ClearsTabAndDueDate() public {
        _pay(_intent(50 * USDC, 1, false));
        vm.prank(owner);
        uint256 paid = tabs.repay(lineId, 1_000 * USDC); // overpay is capped
        assertEq(paid, 50 * USDC);
        assertEq(_outstanding(lineId), 0);
        assertEq(_dueAt(lineId), 0);
        assertEq(pool.outstanding(), 0);
        assertEq(pool.idle(), 1_000_000 * USDC + 0.25e6, "principal back plus the lenders' fee share");
    }

    function test_PartialRepay_KeepsDueDate() public {
        _pay(_intent(50 * USDC, 1, false));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 due = _dueAt(lineId);
        assertEq(due, vm.getBlockTimestamp() + 3 days);
        vm.prank(owner);
        tabs.repay(lineId, 20 * USDC);
        assertEq(_outstanding(lineId), 30 * USDC);
        assertEq(_dueAt(lineId), due);
    }

    function test_RevertWhen_RepayNothingOwed() public {
        vm.expectRevert(TabManager.ZeroAmount.selector);
        tabs.repay(lineId, 1);
    }

    // ------------------------------------------------------------ collateral

    function test_WithdrawCollateral_OnlyFreePart() public {
        _pay(_intent(100 * USDC, 1, false));
        assertEq(tabs.freeCollateral(lineId), 900 * USDC);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(TabManager.CollateralLocked.selector, 901 * USDC, 900 * USDC));
        tabs.withdrawCollateral(lineId, 901 * USDC, owner);
        tabs.withdrawCollateral(lineId, 900 * USDC, owner);
        vm.stopPrank();
        assertEq(_collateral(lineId), 100 * USDC);
    }

    function test_RevertWhen_StrangerTouchesLine() public {
        address mallory = makeAddr("mallory");
        vm.startPrank(mallory);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.withdrawCollateral(lineId, 1, mallory);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setAgent(lineId, mallory);
        vm.expectRevert(TabManager.NotLineOwner.selector);
        tabs.setMandate(lineId, 1, 1, 1, bytes32(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ default

    function test_PastDue_BlocksNewPayments() public {
        _pay(_intent(10 * USDC, 1, false));
        vm.warp(vm.getBlockTimestamp() + 7 days + 3 days + 1);
        _payExpectRevert(_intent(10 * USDC, 2, false), abi.encodeWithSelector(TabManager.PastDue.selector));
    }

    function test_Liquidate_AfterGrace_NoLossToPool() public {
        _pay(_intent(100 * USDC, 1, false));
        uint256 assetsBefore = pool.totalAssets() + pool.unvestedYield(); // the fee has unlocked by liquidation

        vm.warp(vm.getBlockTimestamp() + 7 days + 3 days + 2 days);
        vm.expectRevert(TabManager.NotPastDue.selector);
        tabs.liquidate(lineId);

        vm.warp(vm.getBlockTimestamp() + 1);
        (uint256 seized, uint256 loss) = tabs.liquidate(lineId);
        assertEq(seized, 100 * USDC);
        assertEq(loss, 0);
        assertEq(_collateral(lineId), 900 * USDC);
        assertEq(_outstanding(lineId), 0);
        assertEq(pool.outstanding(), 0);
        assertEq(pool.totalAssets(), assetsBefore, "secured default costs depositors nothing");
    }

    // ------------------------------------------------------------ admin

    function test_RevertWhen_UnsecuredLtv() public {
        vm.prank(admin);
        vm.expectRevert(TabManager.BadParams.selector);
        tabs.setParams(10_001, 100, 7 days, 3 days, 2 days);
    }

    function test_RevertWhen_DueDatesCouldMerge() public {
        vm.prank(admin);
        vm.expectRevert(TabManager.BadParams.selector);
        tabs.setParams(10_000, 100, 1 days, 3 days, 2 days);
    }

    function test_RevertWhen_EscrowSetTwice() public {
        vm.prank(admin);
        vm.expectRevert(TabManager.EscrowAlreadySet.selector);
        tabs.setEscrow(makeAddr("x"));
    }

    function test_RevertWhen_NonManagerFundsPool() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), pool.MANAGER_ROLE()
            )
        );
        pool.fund(address(this), 1);
    }

    // ------------------------------------------------------------ review regressions

    /// M-2: a draw late in a cycle still gets the full payment window.
    function test_LateDraw_GetsFullPaymentWindow() public {
        _pay(_intent(10 * USDC, 1, false));
        vm.warp(vm.getBlockTimestamp() + 7 days - 1); // last second of the cycle
        _pay(_intent(100 * USDC, 2, false));
        vm.warp(vm.getBlockTimestamp() + 1); // cycle closes
        assertEq(_dueAt(lineId), vm.getBlockTimestamp() + 3 days);
        vm.warp(vm.getBlockTimestamp() + 3 days + 2 days);
        assertFalse(lens.isPastDue(lineId), "not liquidatable inside window + grace");
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(lens.isPastDue(lineId));
    }

    /// Spending after a cycle closes starts a new cycle with its own due date.
    function test_NewCycle_AfterClose() public {
        _pay(_intent(10 * USDC, 1, false));
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        _pay(_intent(20 * USDC, 2, false));
        (uint256 billed, uint256 unbilled,,,) = lens.statementOf(lineId);
        assertEq(billed, 10 * USDC);
        assertEq(unbilled, 20 * USDC);
        vm.prank(owner);
        tabs.repay(lineId, 10 * USDC); // pays the statement first
        (billed, unbilled,,,) = lens.statementOf(lineId);
        assertEq(billed, 0);
        assertEq(unbilled, 20 * USDC);
        assertEq(_dueAt(lineId), 0);
    }

    /// L-1: revoking a mandate kills intents signed under it, even if a new mandate is set.
    function test_RevokedIntent_CannotRevive() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, agentPk);
        vm.startPrank(owner);
        tabs.revokeMandate(lineId);
        tabs.setMandate(
            lineId, uint128(100 * USDC), uint128(500 * USDC), uint64(vm.getBlockTimestamp() + 1 days), bytes32(0)
        );
        vm.stopPrank();
        vm.expectRevert(TabManager.StaleEpoch.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_AgentRotation_InvalidatesOldIntents() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 1, false);
        bytes memory sig = _sign(p, agentPk);
        vm.startPrank(owner);
        tabs.setAgent(lineId, makeAddr("newAgent"));
        tabs.setAgent(lineId, agent); // rotate back
        vm.stopPrank();
        vm.expectRevert(TabManager.StaleEpoch.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function test_CancelNonce() public {
        TabManager.PaymentIntent memory p = _intent(10 * USDC, 9, false);
        bytes memory sig = _sign(p, agentPk);
        vm.prank(owner);
        tabs.cancelNonce(lineId, 9);
        vm.expectRevert(TabManager.NonceUsed.selector);
        tabs.pay(p, sig, new bytes32[](0));
    }

    /// L-2: protocol contracts cannot be sellers.
    function test_RevertWhen_SellerIsProtocolAddress() public {
        address[4] memory bad = [address(tabs), address(escrow), address(pool), treasury];
        for (uint256 i = 0; i < 4; i++) {
            TabManager.PaymentIntent memory p = _intent(10 * USDC, i + 1, false);
            p.seller = bad[i];
            _payExpectRevert(p, abi.encodeWithSelector(TabManager.BadSeller.selector));
        }
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_PayThenRepay(uint256 amount, uint256 repayAmount) public {
        amount = bound(amount, 100, 100 * USDC); // below 100 units the 1% fee would take everything
        repayAmount = bound(repayAmount, 1, 200 * USDC);
        _pay(_intent(amount, 1, false));
        vm.prank(owner);
        uint256 paid = tabs.repay(lineId, repayAmount);
        assertEq(paid, repayAmount < amount ? repayAmount : amount);
        assertEq(_outstanding(lineId), amount - paid);
        assertEq(pool.outstanding(), amount - paid);
        assertLe(_outstanding(lineId), _collateral(lineId));
    }

    function testFuzz_FeeNeverExceedsAmount(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 100 * USDC);
        feeBps = uint16(bound(feeBps, 0, 500));
        vm.prank(admin);
        tabs.setParams(10_000, feeBps, 7 days, 3 days, 2 days);
        uint256 fee = (amount * feeBps + 9_999) / 10_000;
        if (fee >= amount) {
            TabManager.PaymentIntent memory p = _intent(amount, 1, false);
            bytes memory sig = _sign(p, agentPk);
            vm.expectRevert(TabManager.AmountTooSmall.selector);
            tabs.pay(p, sig, new bytes32[](0));
            return;
        }
        _pay(_intent(amount, 1, false));
        assertGt(usdc.balanceOf(seller), 0, "seller always receives something");
        uint256 poolGain = pool.idle() - (1_000_000 * USDC - amount);
        assertEq(usdc.balanceOf(seller) + tabs.feesAccrued() + poolGain, amount, "every unit accounted for");
        assertGe(amount - usdc.balanceOf(seller), feeBps == 0 ? 0 : 1, "fee rounds up");
    }
}

contract CreditPoolTest is BaseTest {
    function test_WithdrawLimitedToIdle() public {
        vm.prank(owner);
        tabs.setMandate(
            lineId, uint128(1_000 * USDC), uint128(1_000 * USDC), uint64(vm.getBlockTimestamp() + 1 days), bytes32(0)
        );
        _pay(_intent(1_000 * USDC, 1, false));
        assertEq(pool.totalAssets(), 1_000_000 * USDC, "fee still locked");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(pool.maxWithdraw(lp), 999_005 * USDC);
        assertEq(pool.totalAssets(), 1_000_005 * USDC);
    }

    function test_DepositCap() public {
        vm.prank(admin);
        pool.setDepositCap(1_000_100 * USDC);
        assertEq(pool.maxDeposit(lp), 100 * USDC);
        usdc.mint(lp, 200 * USDC);
        vm.prank(lp);
        vm.expectRevert();
        pool.deposit(101 * USDC, lp);
    }

    function test_InflationAttackBlunted() public {
        CreditPool fresh = new CreditPool(usdc, admin, 0);
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        usdc.mint(attacker, 10_001 * USDC);
        usdc.mint(victim, 10_000 * USDC);

        vm.startPrank(attacker);
        usdc.approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker);
        usdc.transfer(address(fresh), 10_000 * USDC); // donation
        vm.stopPrank();

        vm.startPrank(victim);
        usdc.approve(address(fresh), type(uint256).max);
        uint256 shares = fresh.deposit(10_000 * USDC, victim);
        vm.stopPrank();
        assertGt(shares, 0, "victim still receives shares");
        assertApproxEqRel(fresh.previewRedeem(shares), 10_000 * USDC, 0.001e18);
    }

    /// Audit finding: one line cannot lend out more than the utilization cap.
    function test_UtilizationCap_KeepsWithdrawalBuffer() public {
        address whale = makeAddr("whale");
        usdc.mint(whale, 2_000_000 * USDC);
        uint256 pk = 0xBEEF;
        vm.startPrank(whale);
        usdc.approve(address(tabs), type(uint256).max);
        uint256 id = tabs.openLine(vm.addr(pk));
        tabs.depositCollateral(id, 2_000_000 * USDC);
        tabs.setMandate(id, type(uint128).max, type(uint128).max, uint64(vm.getBlockTimestamp() + 1 days), bytes32(0));
        vm.stopPrank();

        TabManager.PaymentIntent memory p = TabManager.PaymentIntent({
            lineId: id,
            epoch: tabs.getLine(id).epoch,
            seller: whale,
            amount: 950_000 * USDC,
            resource: bytes32(0),
            escrowed: false,
            nonce: 1,
            deadline: vm.getBlockTimestamp() + 1 hours
        });
        bytes memory sig = _sign(p, pk);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.UtilizationCap.selector, 950_000 * USDC, 900_000 * USDC));
        tabs.pay(p, sig, new bytes32[](0));

        p.amount = 900_000 * USDC;
        sig = _sign(p, pk);
        tabs.pay(p, sig, new bytes32[](0));
        assertGe(pool.maxWithdraw(lp), 100_000 * USDC, "lenders keep a 10% buffer");
    }

    function test_SweepFees_GoesToTreasury() public {
        _pay(_intent(40 * USDC, 1, false));
        uint256 amount = tabs.sweepFees();
        assertEq(amount, 0.2e6);
        assertEq(usdc.balanceOf(treasury), 0.2e6);
        assertEq(tabs.feesAccrued(), 0);
    }

    /// Audit lead: a blocked treasury no longer blocks payments, only the sweep.
    function test_BlockedTreasury_DoesNotBlockPayments() public {
        usdc.setBlacklisted(treasury, true);
        _pay(_intent(40 * USDC, 1, false));
        assertEq(usdc.balanceOf(seller), 39.6e6);
        vm.expectRevert();
        tabs.sweepFees();
    }

    function test_PoolFeeShare_IsAdjustable() public {
        vm.prank(admin);
        tabs.setPoolFeeShare(0);
        _pay(_intent(40 * USDC, 1, false));
        assertEq(tabs.feesAccrued(), 0.4e6, "all to the treasury at 0%");
        assertEq(pool.idle(), 1_000_000 * USDC - 40 * USDC);
    }

    /// Lenders who deposit earn: share value rises with every fee-paying payment.
    function test_LenderShareValue_GrowsWithFees() public {
        uint256 before = pool.convertToAssets(1e12);
        for (uint256 i = 1; i <= 5; i++) {
            _pay(_intent(100 * USDC, i, false));
        }
        vm.prank(owner);
        tabs.repay(lineId, 500 * USDC);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(pool.convertToAssets(1e12), before);
        assertEq(pool.totalAssets(), 1_000_000 * USDC + 2.5e6, "half of 5 USDC in fees");
    }
}
