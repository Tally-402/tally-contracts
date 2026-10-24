// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title ScoreRegistry
/// @notice Public, verifiable Tally Scores. Each epoch, the Score engine publishes one Merkle root that
///         commits to every payer's score. Anyone can check a score with a proof, and anyone can record a
///         proven score on-chain so other contracts can read it with a plain call.
///
///         One root per epoch keeps the cost flat on Ethereum (about one storage write, whatever the number
///         of payers). The same root is published on Base so payment contracts there can read it cheaply.
///
///         Leaves follow the OpenZeppelin StandardMerkleTree format:
///         keccak256(bytes.concat(keccak256(abi.encode(epoch, ScoreLeaf)))).
contract ScoreRegistry is AccessControl {
    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    /// @notice One payer's score in one epoch. Mirrors the Score API, scaled to integers.
    struct ScoreLeaf {
        address subject; // the payer's wallet
        uint16 score; // 0-1000
        uint16 breadth; // 0-250
        uint16 tenure; // 0-200
        uint16 consistency; // 0-150
        uint16 volume; // 0-200
        uint16 cleanliness; // 0-200
        uint16 screenedOutBps; // share of the payer's volume removed by wash screening, 0-10000
        bool agentLikely;
        uint64 keptVolumeCents; // screened x402 volume, US cents
        uint64 firstSeen; // unix time of the first clean payment
    }

    struct Epoch {
        bytes32 root;
        uint64 asOf; // unix time the scores were computed
        uint32 count; // number of leaves
        uint16 version; // scoring method version
        bool revoked;
        string uri; // full snapshot with every leaf and proof (IPFS or HTTPS)
    }

    struct Recorded {
        uint16 score;
        bool agentLikely;
        uint64 epoch;
        uint64 asOf;
    }

    mapping(uint64 epoch => Epoch) internal _epochs;
    mapping(address subject => Recorded) internal _recorded;

    /// @notice Highest epoch ever published (it may since have been revoked).
    uint64 public latestEpoch;

    event Published(uint64 indexed epoch, bytes32 root, uint64 asOf, uint32 count, uint16 version, string uri);
    event Revoked(uint64 indexed epoch);
    event ScoreRecorded(address indexed subject, uint64 indexed epoch, uint16 score, bool agentLikely);

    error EpochNotNewer(uint64 epoch, uint64 latest);
    error EpochInFuture(uint64 epoch);
    error BadSnapshot();
    error UnknownEpoch(uint64 epoch);
    error EpochRevoked(uint64 epoch);
    error InvalidProof();
    error StaleRecord(uint64 epoch, uint64 recorded);

    constructor(address admin, address publisher) {
        if (admin == address(0) || publisher == address(0)) revert BadSnapshot();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PUBLISHER_ROLE, publisher);
    }

    // ---------------------------------------------------------------- publishing

    /// @notice Publish the scores for a new epoch. The epoch is a UTC day number (unix time / 1 day), so epochs
    ///         only move forward and never past today: a leaked publisher key can't block future snapshots.
    function publish(uint64 epoch, bytes32 root, uint64 asOf, uint32 count, uint16 version, string calldata uri)
        external
        onlyRole(PUBLISHER_ROLE)
    {
        if (epoch <= latestEpoch) revert EpochNotNewer(epoch, latestEpoch);
        if (epoch > block.timestamp / 1 days) revert EpochInFuture(epoch);
        if (root == bytes32(0) || count == 0 || asOf == 0 || asOf > block.timestamp) revert BadSnapshot();
        _epochs[epoch] = Epoch(root, asOf, count, version, false, uri);
        latestEpoch = epoch;
        emit Published(epoch, root, asOf, count, version, uri);
    }

    /// @notice Withdraw a bad snapshot. Its proofs stop verifying and its recorded scores read as missing.
    function revoke(uint64 epoch) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Epoch storage e = _epochs[epoch];
        if (e.root == bytes32(0)) revert UnknownEpoch(epoch);
        e.revoked = true;
        emit Revoked(epoch);
    }

    // ---------------------------------------------------------------- reading

    function leafHash(uint64 epoch, ScoreLeaf calldata leaf) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, leaf))));
    }

    /// @notice True if `leaf` is in a live (published, not revoked) epoch.
    function verify(uint64 epoch, ScoreLeaf calldata leaf, bytes32[] calldata proof) public view returns (bool) {
        Epoch storage e = _epochs[epoch];
        if (e.root == bytes32(0) || e.revoked) return false;
        return MerkleProof.verifyCalldata(proof, e.root, leafHash(epoch, leaf));
    }

    /// @notice Store a proven score so contracts can read it with `scoreOf`. Anyone may call.
    function record(uint64 epoch, ScoreLeaf calldata leaf, bytes32[] calldata proof) external {
        Epoch storage e = _epochs[epoch];
        if (e.root == bytes32(0)) revert UnknownEpoch(epoch);
        if (e.revoked) revert EpochRevoked(epoch);
        if (!MerkleProof.verifyCalldata(proof, e.root, leafHash(epoch, leaf))) revert InvalidProof();
        Recorded storage r = _recorded[leaf.subject];
        // A newer record wins, unless its epoch was revoked: then an older valid score may replace it.
        if (epoch <= r.epoch && !_epochs[r.epoch].revoked) revert StaleRecord(epoch, r.epoch);
        _recorded[leaf.subject] = Recorded(leaf.score, leaf.agentLikely, epoch, e.asOf);
        emit ScoreRecorded(leaf.subject, epoch, leaf.score, leaf.agentLikely);
    }

    /// @notice The latest recorded score for `subject`. `found` is false if none is recorded or its epoch
    ///         was revoked. Callers should check `asOf` against their own freshness limit.
    function scoreOf(address subject)
        external
        view
        returns (bool found, uint16 score, bool agentLikely, uint64 epoch, uint64 asOf)
    {
        Recorded memory r = _recorded[subject];
        if (r.epoch == 0 || _epochs[r.epoch].revoked) return (false, 0, false, 0, 0);
        return (true, r.score, r.agentLikely, r.epoch, r.asOf);
    }

    function getEpoch(uint64 epoch) external view returns (Epoch memory) {
        return _epochs[epoch];
    }
}
