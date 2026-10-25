// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev ERC-4626 lending vault stand-in. Yield = mint the asset to it. `liquidCap` limits withdrawals,
///      like a lending market whose cash is lent out.
contract MockVault is ERC4626 {
    uint256 public liquidCap = type(uint256).max;

    constructor(IERC20 asset_) ERC20("Mock Vault USDC", "mvUSDC") ERC4626(asset_) {}

    function setLiquidCap(uint256 c) external {
        liquidCap = c;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), liquidCap);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), convertToShares(liquidCap));
    }
}
