// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentAccounts, IAgentWallets} from "../src/AgentAccounts.sol";

/// @notice Deploys AgentAccounts (prepaid accounts with agent refills). It has no admin and no wiring.
///
/// Env: USDC      token address (Base Sepolia Circle USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e)
///      IDENTITY  ERC-8004 Identity Registry (Base Sepolia: 0x8004A818BFB912233c491871b3d84c89A494BD9e, Base: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
///
/// Run (keys stay in your keystore):
///   forge script script/DeployAgentAccounts.s.sol --rpc-url $BASE_SEPOLIA_RPC --account deployer --broadcast
contract DeployAgentAccounts is Script {
    function run() external returns (AgentAccounts accounts) {
        IERC20 usdc = IERC20(vm.envAddress("USDC"));
        vm.startBroadcast();
        accounts = new AgentAccounts(usdc, IAgentWallets(vm.envAddress("IDENTITY")));
        vm.stopBroadcast();
        console.log("AgentAccounts", address(accounts));
    }
}
