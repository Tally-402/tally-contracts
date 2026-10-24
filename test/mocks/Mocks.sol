// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev 6-decimal stand-in for USDC.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    mapping(address => bool) public blacklisted;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address a, bool b) external {
        blacklisted[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, value);
    }
}

/// @dev Minimal smart-wallet agent: accepts signatures from one EOA signer (ERC-1271).
contract MockSmartWallet is IERC1271 {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec,,) = ECDSA.tryRecover(hash, sig);
        return rec == signer ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}
