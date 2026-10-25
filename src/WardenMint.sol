// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IWardensMint {
    function mint(address to, uint256 quantity) external returns (uint256 firstId);
}

/// @title WardenMint
/// @notice The one-wave sale of Tally Wardens: an allowlist window (IMD seat holders and ERC-8004 agent owners),
///         then a public window, at one fixed price. The terms lock when the allowlist window opens. Proceeds go
///         only to the first-loss receiver, which seeds the credit pool's junior tranche.
contract WardenMint is Ownable2Step, ReentrancyGuard {
    struct Config {
        uint64 allowlistStart;
        uint64 publicStart; // allowlist closes, public opens
        uint64 end;
        uint16 maxPerWallet; // across both windows
        uint128 price; // wei per Warden
        bytes32 allowlistRoot; // StandardMerkleTree leaves: abi.encode(address)
    }

    IWardensMint public immutable wardens;
    address public immutable firstLossReceiver;

    Config public config;
    mapping(address => uint256) public mintedBy;

    event Configured(Config config);
    event Minted(address indexed to, uint256 firstId, uint256 quantity, bool allowlist);
    event ProceedsSent(address indexed to, uint256 amount);

    error ZeroAddress();
    error BadConfig();
    error TermsLocked();
    error Closed();
    error NotOnAllowlist();
    error WalletLimit();
    error WrongPayment();
    error TransferFailed();

    constructor(address owner_, IWardensMint wardens_, address firstLossReceiver_) Ownable(owner_) {
        if (address(wardens_) == address(0) || firstLossReceiver_ == address(0)) revert ZeroAddress();
        wardens = wardens_;
        firstLossReceiver = firstLossReceiver_;
    }

    /// @notice Set dates, price, wallet limit and allowlist. Locked once the allowlist window opens.
    function configure(Config calldata c) external onlyOwner {
        if (config.allowlistStart != 0 && block.timestamp >= config.allowlistStart) revert TermsLocked();
        if (c.allowlistStart < block.timestamp || c.allowlistStart > c.publicStart || c.publicStart >= c.end) {
            revert BadConfig();
        }
        if (c.maxPerWallet == 0) revert BadConfig();
        config = c;
        emit Configured(c);
    }

    function mintAllowlist(uint256 quantity, bytes32[] calldata proof) external payable nonReentrant returns (uint256) {
        Config memory c = config;
        if (c.allowlistStart == 0 || block.timestamp < c.allowlistStart || block.timestamp >= c.publicStart) {
            revert Closed();
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        if (!MerkleProof.verifyCalldata(proof, c.allowlistRoot, leaf)) revert NotOnAllowlist();
        return _mint(c, quantity, true);
    }

    function mintPublic(uint256 quantity) external payable nonReentrant returns (uint256) {
        Config memory c = config;
        if (c.allowlistStart == 0 || block.timestamp < c.publicStart || block.timestamp >= c.end) revert Closed();
        return _mint(c, quantity, false);
    }

    function _mint(Config memory c, uint256 quantity, bool allowlist) internal returns (uint256 firstId) {
        if (quantity == 0 || msg.value != uint256(c.price) * quantity) revert WrongPayment();
        if (mintedBy[msg.sender] + quantity > c.maxPerWallet) revert WalletLimit();
        mintedBy[msg.sender] += quantity;
        firstId = wardens.mint(msg.sender, quantity);
        emit Minted(msg.sender, firstId, quantity, allowlist);
    }

    /// @notice Send the proceeds to the first-loss receiver. Anyone may call.
    function sendProceeds() external nonReentrant {
        uint256 amount = address(this).balance;
        (bool ok,) = firstLossReceiver.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ProceedsSent(firstLossReceiver, amount);
    }
}
