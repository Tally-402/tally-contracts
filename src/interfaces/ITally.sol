// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IEscrow {
    function open(uint256 lineId, address seller, uint256 amount, uint256 fee, bytes32 resource)
        external
        returns (uint256 holdId);
}

/// @notice Escrow's wiring, checked once by TabManager.setEscrow.
interface IEscrowWiring {
    function manager() external view returns (ITabManager);
}

interface ITabManager {
    /// @notice Escrow released a hold to the seller and sent the fee to the manager:
    ///         the amount becomes billable to the owner and the fee is distributed.
    function onRelease(uint256 lineId, uint256 holdId, uint256 amount, uint256 fee) external;
    /// @notice Escrow sent a refunded hold back to the manager.
    function creditRefund(uint256 lineId, uint256 holdId, uint256 amount) external;
}
