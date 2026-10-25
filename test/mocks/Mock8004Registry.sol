// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev ERC-8004 IdentityRegistry stand-in with the behaviour the Wardens contract relies on: identities are
///      ERC-721s minted with _safeMint, only the owner or an approved operator manages one, the agent wallet
///      proves control with a signature, and a transfer clears the agent wallet. Test-only.
contract Mock8004Registry is ERC721 {
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event MetadataSet(
        uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue
    );

    uint256 public nextId = 1;
    mapping(uint256 => string) public agentURIOf;
    mapping(uint256 => address) internal _wallet;
    mapping(uint256 => mapping(string => bytes)) internal _meta;

    constructor() ERC721("Mock 8004", "AGENT") {}

    modifier onlyAgentOwner(uint256 id) {
        require(_isAuthorized(_requireOwned(id), msg.sender, id), "not agent owner");
        _;
    }

    function register(string calldata agentURI) external returns (uint256 id) {
        id = nextId++;
        agentURIOf[id] = agentURI;
        _safeMint(msg.sender, id);
        emit Registered(id, agentURI, msg.sender);
    }

    function setAgentURI(uint256 id, string calldata uri) external onlyAgentOwner(id) {
        agentURIOf[id] = uri;
    }

    function setMetadata(uint256 id, string memory key, bytes memory value) external onlyAgentOwner(id) {
        _meta[id][key] = value;
        emit MetadataSet(id, key, key, value);
    }

    function getMetadata(uint256 id, string memory key) external view returns (bytes memory) {
        return _meta[id][key];
    }

    /// @dev The new wallet signs keccak256(registry, agentId, wallet, deadline) as a personal message.
    function walletDigest(uint256 id, address wallet, uint256 deadline) public view returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(address(this), id, wallet, deadline)));
    }

    function setAgentWallet(uint256 id, address wallet, uint256 deadline, bytes calldata sig)
        external
        onlyAgentOwner(id)
    {
        require(block.timestamp <= deadline, "expired");
        require(ECDSA.recover(walletDigest(id, wallet, deadline), sig) == wallet, "bad wallet signature");
        _wallet[id] = wallet;
    }

    function unsetAgentWallet(uint256 id) external onlyAgentOwner(id) {
        _wallet[id] = address(0);
    }

    function getAgentWallet(uint256 id) external view returns (address) {
        return _wallet[id];
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from != address(0)) _wallet[id] = address(0);
    }
}
