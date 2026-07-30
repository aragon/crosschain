// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/// @notice A cross-chain message transaction. Encoded on the origin chain, carried
///         as the bridge payload, and decoded on the destination chain. Every
///         field the destination authenticates against travels INSIDE this
///         transaction, so it is covered by the bridge's payload attestation rather
///         than taken on the adapter's word.
/// @param nonce The origin controller's monotonic nonce for this lane. Owns the
///        message identity; makes it unique in a namespace the origin controls.
/// @param origin The originating address that initiated forwardMessage on `CrossChainController`.
/// @param controller The address of the controller to ensure that re-deploying the
///                   controller will not cause tx id collision.
/// @param originChainId The standard chain id the message was sent from.
/// @param destinationChainId The standard chain id the message may execute on.
/// @param message The encoded `Action[]` payload.
struct Transaction {
    uint256 nonce;
    address origin;
    address controller;
    uint256 originChainId;
    uint256 destinationChainId;
    bytes message;
}

enum TransactionState {
    None,
    Delivered,
    Executed,
    Cancelled
}

/// @notice What the controller retains about a message it has seen.
/// @dev Both fields share one storage slot, so recording the delivery time
///      costs no extra `SSTORE` on the receive path.
/// @param state The delivery/execution state of the message.
/// @param bridgedAt The `block.timestamp` at which the message was delivered.
///        `0` for a txId that was never delivered.
struct TransactionRecord {
    TransactionState state;
    uint120 bridgedAt;
}

library TransactionLib {
    using TransactionLib for Transaction;

    function encode(Transaction memory _transaction) internal pure returns (bytes memory) {
        return abi.encode(_transaction);
    }

    function decode(bytes memory _payload) internal pure returns (Transaction memory) {
        return abi.decode(_payload, (Transaction));
    }

    function id(Transaction memory _transaction) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(_transaction));
    }

    function id(bytes memory _transaction) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(_transaction);
    }
}
