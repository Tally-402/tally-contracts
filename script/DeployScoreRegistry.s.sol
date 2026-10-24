// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ScoreRegistry} from "../src/ScoreRegistry.sol";

/// @notice Deploys ScoreRegistry. Run on Ethereum (Sepolia first), and again on Base for the mirror.
///
/// Env:
///   ADMIN      admin who can revoke a bad snapshot (a Safe on mainnet)
///   PUBLISHER  the Score engine's publishing key (holds gas money only)
///
/// Run (keys stay in your keystore, never in env):
///   forge script script/DeployScoreRegistry.s.sol --rpc-url $SEPOLIA_RPC --account deployer --broadcast
contract DeployScoreRegistry is Script {
    function run() external returns (ScoreRegistry reg) {
        address admin = vm.envAddress("ADMIN");
        address publisher = vm.envAddress("PUBLISHER");
        vm.startBroadcast();
        reg = new ScoreRegistry(admin, publisher);
        vm.stopBroadcast();
        console.log("ScoreRegistry", address(reg));
    }
}
