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

    struct Entry {
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
    }

    mapping(uint256 => mapping(address => mapping(uint64 => Entry))) public entries;

    /// @dev The full ERC-8004 giveFeedback.
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external {
        uint64 idx = ++lastIndex[agentId][msg.sender];
        entries[agentId][msg.sender][idx] = Entry(value, valueDecimals, tag1, tag2);
        _emitFull(agentId, idx, value, valueDecimals, tag1, tag2, abi.encode(endpoint, feedbackURI, feedbackHash));
    }

    function _emitFull(
        uint256 agentId,
        uint64 idx,
        int128 value,
        uint8 dec,
        string memory tag1,
        string memory tag2,
        bytes memory rest
    ) internal {
        (string memory endpoint, string memory uri, bytes32 h) = abi.decode(rest, (string, string, bytes32));
        emit NewFeedback(agentId, msg.sender, idx, value, dec, tag1, tag1, tag2, endpoint, uri, h);
    }

    function readFeedback(uint256 agentId, address client, uint64 idx)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked)
    {
        Entry storage e = entries[agentId][client][idx];
        return (e.value, e.valueDecimals, e.tag1, e.tag2, false);
    }

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }
}
