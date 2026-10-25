// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentAccounts, IAgentWallets} from "../src/AgentAccounts.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

contract AgentAccountsTest is Test {
    uint256 constant U = 1e6;
    MockUSDC usdc;
    AgentAccounts acc;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address worker = makeAddr("worker");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        acc = new AgentAccounts(usdc, IAgentWallets(address(0)));
        usdc.mint(owner, 1_000 * U);
        vm.startPrank(owner);
        usdc.approve(address(acc), type(uint256).max);
        acc.deposit(200 * U);
        acc.setAgent(agent, uint128(5 * U), uint128(20 * U), uint128(50 * U));
        vm.stopPrank();
    }

    function _spend(address a, uint256 amount) internal {
        vm.prank(a);
        usdc.transfer(stranger, amount);
    }

    function test_deposit_and_withdraw() public {
        assertEq(acc.balanceOf(owner), 200 * U);
        vm.prank(owner);
        acc.withdraw(50 * U, owner);
        assertEq(acc.balanceOf(owner), 150 * U);
        assertEq(usdc.balanceOf(owner), 850 * U);
    }

    function test_depositFor_credits_the_owner() public {
        usdc.mint(stranger, 30 * U);
        vm.startPrank(stranger);
        usdc.approve(address(acc), 30 * U);
        acc.depositFor(owner, 30 * U);
        vm.stopPrank();
        assertEq(acc.balanceOf(owner), 230 * U);
        assertEq(acc.balanceOf(stranger), 0);
    }

    function test_only_owner_can_withdraw_its_balance() public {
        vm.prank(stranger);
        vm.expectRevert(AgentAccounts.InsufficientBalance.selector);
        acc.withdraw(1, stranger);
    }

    function test_refill_empty_wallet_to_target_by_anyone() public {
        vm.prank(keeper);
        uint256 got = acc.refill(owner, agent);
        assertEq(got, 20 * U);
        assertEq(usdc.balanceOf(agent), 20 * U);
        assertEq(acc.balanceOf(owner), 180 * U);
    }

    function test_no_refill_at_or_above_floor() public {
        acc.refill(owner, agent);
        _spend(agent, 15 * U); // 5 left = floor
        assertEq(acc.refillable(owner, agent), 0);
        vm.expectRevert(AgentAccounts.NothingToRefill.selector);
        acc.refill(owner, agent);
        _spend(agent, 1); // just under
        assertEq(acc.refillable(owner, agent), 15 * U + 1);
    }

    function test_daily_cap_then_reset_next_day() public {
        acc.refill(owner, agent); // 20
        _spend(agent, 20 * U);
        acc.refill(owner, agent); // 40
        _spend(agent, 20 * U);
        assertEq(acc.refill(owner, agent), 10 * U); // capped at 50 for the day
        _spend(agent, 10 * U);
        vm.expectRevert(AgentAccounts.NothingToRefill.selector);
        acc.refill(owner, agent);
        vm.warp(block.timestamp + 1 days);
        assertEq(acc.refill(owner, agent), 20 * U);
    }

    function test_refill_limited_by_account_balance() public {
        vm.prank(owner);
        acc.withdraw(190 * U, owner); // 10 left
        assertEq(acc.refill(owner, agent), 10 * U);
        assertEq(acc.balanceOf(owner), 0);
        _spend(agent, 10 * U);
        vm.expectRevert(AgentAccounts.NothingToRefill.selector);
        acc.refill(owner, agent);
    }

    function test_pause_blocks_refills_but_not_withdrawals() public {
        vm.prank(owner);
        acc.setPaused(true);
        assertEq(acc.refillable(owner, agent), 0);
        vm.expectRevert(AgentAccounts.AccountPaused.selector);
        acc.refill(owner, agent);
        vm.prank(owner);
        acc.withdraw(200 * U, owner);
        vm.prank(owner);
        acc.setPaused(false);
        vm.expectRevert(AgentAccounts.NothingToRefill.selector); // account is empty now
        acc.refill(owner, agent);
    }

    function test_removed_or_unknown_agent_gets_nothing() public {
        vm.expectRevert(AgentAccounts.NotAgent.selector);
        acc.refill(owner, worker);
        vm.prank(owner);
        acc.removeAgent(agent);
        vm.expectRevert(AgentAccounts.NotAgent.selector);
        acc.refill(owner, agent);
    }

    function test_rules_are_per_owner() public {
        // someone else registering the same agent can't spend owner's balance
        vm.prank(stranger);
        acc.setAgent(agent, uint128(5 * U), uint128(1_000 * U), uint128(1_000 * U));
        vm.expectRevert(AgentAccounts.NothingToRefill.selector); // stranger has no balance
        acc.refill(stranger, agent);
        assertEq(acc.balanceOf(owner), 200 * U);
    }

    function test_several_agents_share_one_account() public {
        vm.prank(owner);
        acc.setAgent(worker, 0, uint128(10 * U), uint128(10 * U));
        acc.refill(owner, agent);
        acc.refill(owner, worker);
        assertEq(usdc.balanceOf(worker), 10 * U);
        assertEq(acc.balanceOf(owner), 170 * U);
        _spend(worker, 1);
        assertEq(acc.refillable(owner, worker), 0); // floor 0: only when empty
    }

    function test_bad_rules_revert() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentAccounts.BadRule.selector);
        acc.setAgent(worker, uint128(10 * U), uint128(5 * U), uint128(50 * U));
        vm.expectRevert(AgentAccounts.BadRule.selector);
        acc.setAgent(worker, 0, 0, uint128(50 * U));
        vm.expectRevert(AgentAccounts.BadRule.selector);
        acc.setAgent(worker, 0, uint128(5 * U), 0);
        vm.expectRevert(AgentAccounts.ZeroAddress.selector);
        acc.setAgent(address(0), 0, uint128(5 * U), uint128(5 * U));
        vm.stopPrank();
    }

    /// Whatever an agent does with its cash, it never receives more than its daily cap per day,
    /// and the contract always holds exactly the sum of balances.
    function testFuzz_daily_cap_and_solvency(uint8 rounds, uint256 seed) public {
        rounds = uint8(bound(rounds, 1, 40));
        uint256 received;
        uint256 day = block.timestamp / 1 days;
        for (uint256 i; i < rounds; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 cash = usdc.balanceOf(agent);
            if (cash > 0) _spend(agent, seed % (cash + 1));
            if (seed % 7 == 0) {
                vm.warp(block.timestamp + 1 days);
                day = block.timestamp / 1 days;
                received = 0;
            }
            uint256 r = acc.refillable(owner, agent);
            if (r > 0) received += acc.refill(owner, agent);
            assertLe(received, 50 * U);
            assertEq(usdc.balanceOf(address(acc)), acc.balanceOf(owner));
            assertEq(block.timestamp / 1 days, day);
        }
    }
}

import {Mock8004Registry} from "./mocks/Mock8004Registry.sol";

contract AgentAccountsBindingTest is Test {
    uint256 constant U = 1e6;
    MockUSDC usdc;
    Mock8004Registry reg;
    AgentAccounts acc;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    uint256 walletPk = 0xBEEF;
    address wallet;
    uint256 agentId;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        reg = new Mock8004Registry();
        acc = new AgentAccounts(usdc, IAgentWallets(address(reg)));
        wallet = vm.addr(walletPk);
        vm.startPrank(owner);
        agentId = reg.register("ipfs://agent");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk, reg.walletDigest(agentId, wallet, block.timestamp + 1));
        reg.setAgentWallet(agentId, wallet, block.timestamp + 1, abi.encodePacked(r, s, v));
        vm.stopPrank();
        usdc.mint(owner, 100 * U);
        vm.startPrank(owner);
        usdc.approve(address(acc), type(uint256).max);
        acc.deposit(100 * U);
        vm.stopPrank();
    }

    function test_add_by_8004_id_resolves_the_payment_wallet() public {
        vm.prank(owner);
        address a = acc.setAgentById(agentId, uint128(1 * U), uint128(10 * U), uint128(50 * U));
        assertEq(a, wallet);
        assertTrue(acc.bindingOk(owner, wallet));
        assertEq(acc.refill(owner, wallet), 10 * U);
    }

    function test_refills_stop_when_the_agent_changes_hands() public {
        vm.prank(owner);
        acc.setAgentById(agentId, uint128(1 * U), uint128(10 * U), uint128(50 * U));
        vm.prank(owner);
        reg.transferFrom(owner, buyer, agentId); // the registry clears the payment wallet on transfer
        assertFalse(acc.bindingOk(owner, wallet));
        assertEq(acc.refillable(owner, wallet), 0);
        vm.expectRevert(AgentAccounts.AgentWalletChanged.selector);
        acc.refill(owner, wallet);
    }

    function test_id_without_a_payment_wallet_reverts() public {
        vm.prank(owner);
        uint256 bare = reg.register("ipfs://bare");
        vm.prank(owner);
        vm.expectRevert(AgentAccounts.NoAgentWallet.selector);
        acc.setAgentById(bare, 0, uint128(10 * U), uint128(10 * U));
    }

    function test_re_adding_by_address_drops_the_binding() public {
        vm.startPrank(owner);
        acc.setAgentById(agentId, uint128(1 * U), uint128(10 * U), uint128(50 * U));
        reg.transferFrom(owner, buyer, agentId);
        acc.setAgent(wallet, uint128(1 * U), uint128(10 * U), uint128(50 * U)); // owner knowingly keeps funding it
        vm.stopPrank();
        assertTrue(acc.bindingOk(owner, wallet));
        assertEq(acc.refill(owner, wallet), 10 * U);
    }

    function test_no_registry_means_no_binding() public {
        AgentAccounts plain = new AgentAccounts(usdc, IAgentWallets(address(0)));
        vm.expectRevert(AgentAccounts.NoRegistry.selector);
        plain.setAgentById(agentId, 0, 1, 1);
    }
}
