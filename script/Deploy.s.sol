// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {TabManager} from "../src/TabManager.sol";
import {Escrow} from "../src/Escrow.sol";
import {ITabManager} from "../src/interfaces/ITally.sol";

/// @notice Deploys and wires CreditPool, TabManager and Escrow.
///
/// Env:
///   USDC         token address (Base Sepolia Circle USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e, verify before use)
///   ADMIN        admin / arbiter (a Safe on mainnet)
///   TREASURY     fee recipient
///   VERIFIER     delivery verifier service address
///   DEPOSIT_CAP  pool cap in USDC base units (6 decimals); 0 = no cap
///
/// Run (keys stay in your keystore, never in env):
///   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --account deployer --broadcast
contract Deploy is Script {
    function run() external returns (CreditPool pool, TabManager tabs, Escrow escrow) {
        IERC20 usdc = IERC20(vm.envAddress("USDC"));
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");
        address verifier = vm.envAddress("VERIFIER");
        uint256 cap = vm.envOr("DEPOSIT_CAP", uint256(10_000e6));

        vm.startBroadcast();
        // The broadcaster, not the script's default msg.sender.
        (, address deployer,) = vm.readCallers();

        // The deployer is temporary admin for wiring, then hands everything to ADMIN.
        pool = new CreditPool(usdc, deployer, cap);
        tabs = new TabManager(usdc, pool, deployer, treasury);
        escrow = new Escrow(usdc, ITabManager(address(tabs)), deployer);

        pool.grantRole(pool.MANAGER_ROLE(), address(tabs));
        tabs.setEscrow(address(escrow));
        escrow.grantRole(escrow.VERIFIER_ROLE(), verifier);
        escrow.grantRole(escrow.ARBITER_ROLE(), admin);

        if (admin != deployer) {
            pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), admin);
            tabs.grantRole(tabs.DEFAULT_ADMIN_ROLE(), admin);
            escrow.grantRole(escrow.DEFAULT_ADMIN_ROLE(), admin);
            pool.renounceRole(pool.DEFAULT_ADMIN_ROLE(), deployer);
            tabs.renounceRole(tabs.DEFAULT_ADMIN_ROLE(), deployer);
            escrow.renounceRole(escrow.DEFAULT_ADMIN_ROLE(), deployer);
        }
        vm.stopBroadcast();

        console.log("CreditPool", address(pool));
        console.log("TabManager", address(tabs));
        console.log("Escrow    ", address(escrow));
    }
}
