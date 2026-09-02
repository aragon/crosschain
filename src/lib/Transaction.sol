// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/// @notice A cross-chain message transaction. Encoded on the origin chain, carried
///         as the bridge payload, and decoded on the destination chain. Every
///         field the destination authenticates against travels INSIDE this
///         transaction, so it is covered by the bridge's payload attestation rather
///         than taken on the adapter's word.
/// @param nonce The origin controller's monotonic nonce, counted globally
///        rather than per lane. Owns the message identity; makes it unique in a
///        namespace the origin controls.
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

/// @notice The lifecycle of a message on the destination chain.
/// @dev `None` means never seen. A `txId` never returns to `None`, so a message
///      that reached any other state can never be delivered again.
enum TransactionState {
    None,
    Delivered,
    Executed,
    Cancelled
}

/// @title TransactionLib
/// @notice Encoding, decoding and identity helpers for `Transaction`.
/// @custom:security-contact sirt@aragon.org
library TransactionLib {
    using TransactionLib for Transaction;

    /// @notice Encodes a transaction into the bridge payload.
    function encode(Transaction memory _transaction) internal pure returns (bytes memory) {
        return abi.encode(_transaction);
    }

    /// @notice Decodes a bridge payload back into a transaction.
    /// @dev Reverts on a payload that is not a valid encoding.
    function decode(bytes memory _payload) internal pure returns (Transaction memory) {
        return abi.decode(_payload, (Transaction));
    }

    /// @notice The transaction's identity: the hash of its canonical encoding.
    /// @dev Use this overload for anything received from outside. Re-encoding
    ///      normalizes the input first, so any decodable representation of the
    ///      same transaction resolves to the same id.
    function id(Transaction memory _transaction) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(_transaction.encode());
    }

    /// @notice The same id, hashed straight from bytes.
    /// @dev Only equals the overload above when `_transaction` is already the
    ///      canonical encoding, i.e. it came from `encode`. Do NOT use it on
    ///      unvalidated input.
    function id(bytes memory _transaction) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(_transaction);
    }
}
