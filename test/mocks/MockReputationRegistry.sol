// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Emits ERC-8004 ReputationRegistry events with the exact signatures from the EIP.
///      Used to test the Score feedback indexer. Test-only.
contract MockReputationRegistry {
    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64 feedbackIndex,
        int128 value,
        uint8 valueDecimals,
        string indexed indexedTag1,
        string tag1,
        string tag2,
        string endpoint,
        string feedbackURI,
        bytes32 feedbackHash
    );
    event FeedbackRevoked(uint256 indexed agentId, address indexed clientAddress, uint64 indexed feedbackIndex);

    mapping(uint256 => mapping(address => uint64)) public lastIndex;

    /// @dev Fewer arguments than the real giveFeedback (stack depth); emits the same event.
    function giveFeedback(uint256 agentId, int128 value, uint8 valueDecimals, string calldata tag1) external {
        uint64 idx = ++lastIndex[agentId][msg.sender];
        emit NewFeedback(agentId, msg.sender, idx, value, valueDecimals, tag1, tag1, "", "", "", bytes32(0));
    }

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }
}
