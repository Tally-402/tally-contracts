// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal ERC-8004 IdentityRegistry for testing the agent profile reader: the ERC-721 reads
///      (ownerOf, tokenURI) plus getAgentWallet, and the Registered event. Test-only.
contract MockIdentityRegistry {
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);

    uint256 public nextId = 1;
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => string) internal _uri;
    mapping(uint256 => address) internal _wallet;

    function register(string calldata agentURI) external returns (uint256 id) {
        id = nextId++;
        _owner[id] = msg.sender;
        _uri[id] = agentURI;
        emit Registered(id, agentURI, msg.sender);
    }

    function setAgentWallet(uint256 id, address wallet) external {
        require(_owner[id] == msg.sender, "not owner");
        _wallet[id] = wallet;
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = _owner[id];
        require(o != address(0), "ERC721NonexistentToken");
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        require(_owner[id] != address(0), "ERC721NonexistentToken");
        return _uri[id];
    }

    function getAgentWallet(uint256 id) external view returns (address) {
        return _wallet[id];
    }
}
