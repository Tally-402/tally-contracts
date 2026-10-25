// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The parts of the ERC-8004 Identity Registry the Wardens contract uses.
interface IIdentityRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function setAgentURI(uint256 agentId, string calldata newURI) external;
    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue) external;
    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory);
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;
    function getAgentWallet(uint256 agentId) external view returns (address);
    function unsetAgentWallet(uint256 agentId) external;
    function ownerOf(uint256 agentId) external view returns (address);
}

/// @notice Renders a Warden's tokenURI. Replaceable until the collection's metadata is frozen.
interface IWardenRenderer {
    function tokenURI(uint256 tokenId) external view returns (string memory);
}
