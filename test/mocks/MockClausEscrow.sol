// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Emits the same events as ClausTokenDealEscrow (Ethereum 0xc2292af8b51109a27a4b4e28e9cf9f3aede4190c,
///      from its verified ABI). Used to test the Score indexer. Test-only: no funds move.
contract MockClausEscrow {
    event Funded(
        bytes32 indexed dealId,
        address indexed buyer,
        address indexed worker,
        uint256 amount,
        bytes32 projectId,
        bytes32 termsHash,
        uint64 deliveryDue
    );
    event Claimed(bytes32 indexed dealId);
    event Delivered(bytes32 indexed dealId, bytes32 resultHash, uint64 reviewDue);
    event Disputed(bytes32 indexed dealId, bytes32 disputeHash, uint64 resolutionDue);
    event Settled(bytes32 indexed dealId, uint256 workerAmount, uint256 buyerAmount, bytes32 evidenceHash);

    function fund(bytes32 id, address worker, uint256 amount) external {
        emit Funded(id, msg.sender, worker, amount, bytes32("prj"), bytes32("terms"), uint64(block.timestamp + 1 days));
    }

    function claim(bytes32 id) external {
        emit Claimed(id);
    }

    function deliver(bytes32 id) external {
        emit Delivered(id, bytes32("result"), uint64(block.timestamp + 1 days));
    }

    function dispute(bytes32 id) external {
        emit Disputed(id, bytes32("why"), uint64(block.timestamp + 3 days));
    }

    function settle(bytes32 id, uint256 toWorker, uint256 toBuyer) external {
        emit Settled(id, toWorker, toBuyer, bytes32(0));
    }
}
