// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Wardens} from "../src/Wardens.sol";
import {WardenMint, IWardensMint} from "../src/WardenMint.sol";
import {IIdentityRegistry} from "../src/interfaces/IWardens.sol";

/// @notice Deploys Wardens and WardenMint on Ethereum (or Sepolia) and wires the sale as the only minter.
///
/// Env:
///   OWNER              final owner of both contracts (a Safe on mainnet; it must call acceptOwnership)
///   FIRST_LOSS         receiver of mint proceeds (the first-loss tranche Safe)
///   IDENTITY_REGISTRY  optional; defaults to the ERC-8004 IdentityRegistry for the chain
///
/// Run (keys stay in your keystore):
///   forge script script/DeployWardens.s.sol --rpc-url $SEPOLIA_RPC --account deployer --broadcast --skip-simulation --slow
/// Ethereum charges more gas per byte of contract code since Glamsterdam; Foundry's local simulation still uses
/// the old price, so skip it and let the node estimate.
contract DeployWardens is Script {
    function run() external returns (Wardens wardens, WardenMint sale) {
        address owner = vm.envAddress("OWNER");
        address firstLoss = vm.envAddress("FIRST_LOSS");
        address registry = vm.envOr("IDENTITY_REGISTRY", address(0));
        if (registry == address(0)) registry = _registry();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        wardens = new Wardens(deployer, IIdentityRegistry(registry));
        sale = new WardenMint(deployer, IWardensMint(address(wardens)), firstLoss);
        wardens.setMinter(address(sale));
        if (owner != deployer) {
            wardens.transferOwnership(owner);
            sale.transferOwnership(owner);
        }
        vm.stopBroadcast();

        console.log("Wardens   ", address(wardens));
        console.log("WardenMint", address(sale));
        if (owner != deployer) console.log("Pending owner (must acceptOwnership on both):", owner);
    }

    function _registry() internal view returns (address) {
        if (block.chainid == 1 || block.chainid == 8453) return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        if (block.chainid == 11155111 || block.chainid == 84532) return 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        revert("set IDENTITY_REGISTRY for this chain");
    }
}
