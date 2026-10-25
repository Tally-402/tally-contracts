// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AgentAccounts, IAgentWallets} from "../src/AgentAccounts.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "./mocks/Mocks.sol";
import {MockVault} from "./mocks/MockVault.sol";

contract AgentAccountsEarnTest is Test {
    uint256 constant U = 1e6;
    MockUSDC usdc;
    AgentAccounts acc;
    MockVault vault;
    MockVault vault2;
    address owner = makeAddr("owner");
    address other = makeAddr("other");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        acc = new AgentAccounts(usdc, IAgentWallets(address(0)));
        vault = new MockVault(usdc);
        vault2 = new MockVault(usdc);
        for (uint256 i; i < 2; i++) {
            address o = i == 0 ? owner : other;
            usdc.mint(o, 1_000 * U);
            vm.startPrank(o);
            usdc.approve(address(acc), type(uint256).max);
            acc.deposit(500 * U);
            acc.setAgent(agent, uint128(5 * U), uint128(20 * U), uint128(100 * U));
            vm.stopPrank();
        }
    }

    function _earn(address o, IERC4626 v, uint256 buffer) internal {
        vm.prank(o);
        acc.setEarn(v, buffer);
    }

    function _spend(uint256 amount) internal {
        vm.prank(agent);
        usdc.transfer(stranger, amount);
    }

    function _solvent() internal view {
        assertEq(usdc.balanceOf(address(acc)), acc.balanceOf(owner) + acc.balanceOf(other));
        assertEq(vault.balanceOf(address(acc)) + vault2.balanceOf(address(acc)), acc.earnShares(owner) + acc.earnShares(other));
    }

    function test_opt_in_supplies_everything_above_the_buffer() public {
        _earn(owner, vault, 50 * U);
        assertEq(acc.balanceOf(owner), 50 * U);
        assertEq(acc.earnValue(owner), 450 * U);
        assertEq(acc.totalOf(owner), 500 * U);
        assertEq(acc.balanceOf(other), 500 * U); // others untouched
        _solvent();
    }

    function test_yield_accrues_to_the_owner() public {
        _earn(owner, vault, 50 * U);
        usdc.mint(address(vault), 45 * U); // the market pays 10% on 450
        assertApproxEqAbs(acc.totalOf(owner), 545 * U, 1);
    }

    function test_two_owners_in_one_vault_split_yield_by_share() public {
        _earn(owner, vault, 0);
        _earn(other, vault, 250 * U);
        usdc.mint(address(vault), 75 * U); // 750 supplied, +10%
        assertApproxEqAbs(acc.earnValue(owner), 550 * U, 2);
        assertApproxEqAbs(acc.earnValue(other), 275 * U, 2);
        _solvent();
    }

    function test_refill_pulls_from_the_vault_when_cash_is_short() public {
        _earn(owner, vault, 0); // all supplied, no cash
        assertEq(acc.balanceOf(owner), 0);
        assertEq(acc.refillable(owner, agent), 20 * U);
        assertEq(acc.refill(owner, agent), 20 * U);
        assertEq(usdc.balanceOf(agent), 20 * U);
        assertApproxEqAbs(acc.totalOf(owner), 480 * U, 1);
        _solvent();
    }

    function test_withdraw_pulls_from_the_vault() public {
        _earn(owner, vault, 10 * U);
        vm.prank(owner);
        acc.withdraw(300 * U, owner);
        assertEq(usdc.balanceOf(owner), 800 * U);
        assertApproxEqAbs(acc.totalOf(owner), 200 * U, 1);
        _solvent();
    }

    function test_sweep_after_new_deposit_and_by_anyone() public {
        _earn(owner, vault, 20 * U);
        vm.prank(owner);
        acc.deposit(100 * U);
        assertEq(acc.balanceOf(owner), 120 * U);
        vm.prank(stranger);
        acc.sweep(owner);
        assertEq(acc.balanceOf(owner), 20 * U);
        assertEq(acc.earnValue(owner), 580 * U);
    }

    function test_opt_out_brings_everything_back() public {
        _earn(owner, vault, 0);
        usdc.mint(address(vault), 50 * U);
        _earn(owner, IERC4626(address(0)), 0);
        assertEq(acc.earnShares(owner), 0);
        assertApproxEqAbs(acc.balanceOf(owner), 550 * U, 1);
        _solvent();
    }

    function test_switching_vaults_moves_the_position() public {
        _earn(owner, vault, 0);
        _earn(owner, vault2, 0);
        assertEq(acc.earnShares(owner), vault2.balanceOf(address(acc)));
        assertEq(vault.balanceOf(address(acc)), 0);
        assertApproxEqAbs(acc.earnValue(owner), 500 * U, 1);
        _solvent();
    }

    function test_illiquid_vault_limits_refills_and_withdrawals() public {
        _earn(owner, vault, 0);
        vault.setLiquidCap(8 * U); // market is mostly lent out
        assertEq(acc.refillable(owner, agent), 8 * U);
        assertEq(acc.refill(owner, agent), 8 * U);
        vm.prank(owner);
        vm.expectRevert(AgentAccounts.InsufficientBalance.selector);
        acc.withdraw(100 * U, owner);
        vm.prank(owner);
        vm.expectRevert(AgentAccounts.VaultIlliquid.selector);
        acc.setEarn(IERC4626(address(vault2)), 0); // can't move a position the vault can't pay out
        _solvent();
    }

    function test_rejects_a_vault_for_another_asset() public {
        MockUSDC other_ = new MockUSDC();
        MockVault wrong = new MockVault(other_);
        vm.prank(owner);
        vm.expectRevert(AgentAccounts.BadVault.selector);
        acc.setEarn(IERC4626(address(wrong)), 0);
    }

    function test_works_with_tally_credit_pool() public {
        address admin = makeAddr("admin");
        CreditPool pool = new CreditPool(usdc, admin, 0);
        _earn(owner, IERC4626(address(pool)), 100 * U);
        assertEq(acc.balanceOf(owner), 100 * U);
        assertApproxEqAbs(acc.earnValue(owner), 400 * U, 1);
        _spend(0);
        assertEq(acc.refill(owner, agent), 20 * U);
        vm.prank(owner);
        acc.withdraw(450 * U, owner);
        assertApproxEqAbs(acc.totalOf(owner), 30 * U, 1);
    }

    /// Random deposits, sweeps, refills, withdrawals, yield and liquidity squeezes across two owners:
    /// the contract's USDC and vault shares always equal the sum of what it owes each owner.
    function testFuzz_solvency(uint256 seed) public {
        _earn(owner, vault, 30 * U);
        _earn(other, vault2, 0);
        for (uint256 i; i < 30; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address o = seed % 2 == 0 ? owner : other;
            uint256 op = (seed >> 8) % 7;
            uint256 amt = ((seed >> 16) % 80 + 1) * U;
            if (op == 0) {
                uint256 d = amt > usdc.balanceOf(o) ? 1 : amt;
                vm.prank(o);
                acc.deposit(d);
            } else if (op == 1) {
                acc.sweep(o);
            } else if (op == 2) {
                if (acc.refillable(o, agent) > 0) acc.refill(o, agent);
            } else if (op == 3) {
                vm.prank(o);
                try acc.withdraw(amt, o) {} catch {}
            } else if (op == 4) {
                usdc.mint(address(seed % 3 == 0 ? vault2 : vault), amt / 10);
            } else if (op == 5) {
                (seed % 3 == 0 ? vault2 : vault).setLiquidCap((seed >> 24) % 2 == 0 ? type(uint256).max : amt);
            } else {
                uint256 c = usdc.balanceOf(agent);
                if (c > 0) _spend(c);
                vm.warp(block.timestamp + 6 hours);
            }
            _solvent();
        }
    }
}
