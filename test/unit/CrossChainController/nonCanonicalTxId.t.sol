// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Transaction, TransactionState, TransactionLib } from "@src/lib/Transaction.sol";

/// @title Non-canonical encoding normalization
/// @notice A `Transaction` has more than one valid ABI encoding: `abi.decode`
///         accepts byte strings with a shifted dynamic-field offset (and
///         garbage in the gap) and decodes them to the same struct. A
///         compromised/buggy origin can therefore deliver a message whose raw
///         bytes differ from the canonical encoding the controller re-derives.
///
///         These tests prove the receive / retry / cancel paths all key the
///         record by the hash of the CANONICAL re-encoding, so the emergency
///         paths work regardless of which representation the caller holds.
contract CrossChainControllerNonCanonicalTxIdTest is CrossChainControllerBase {
    /// @dev Builds a non-canonical encoding of `_t` that still `abi.decode`s to
    ///      the identical struct. It shifts the `message` field's offset by one
    ///      word and inserts an ignored garbage word in the gap.
    ///
    ///      Canonical layout (empty message):
    ///        [0x00] 0x20 top-level offset to the tuple
    ///        [0x20] nonce
    ///        [0x40] origin
    ///        [0x60] controller
    ///        [0x80] originChainId
    ///        [0xa0] destinationChainId
    ///        [0xc0] 0xc0 offset to `message` (relative to tuple start)
    ///        [0xe0] 0x00 message length (0)
    ///
    ///      Non-canonical: bump the message offset 0xc0 -> 0xe0 and splice a
    ///      garbage word between the head and the length word.
    function _nonCanonicalEmptyMessage(Transaction memory _t) internal pure returns (bytes memory) {
        require(_t.message.length == 0, "helper assumes empty message");

        return abi.encodePacked(
            uint256(0x20), // top-level offset to the tuple
            _t.nonce,
            uint256(uint160(_t.origin)),
            uint256(uint160(_t.controller)),
            _t.originChainId,
            _t.destinationChainId,
            uint256(0xe0), // message offset, bumped from canonical 0xc0
            uint256(0xdeadbeef), // garbage word in the gap — never read by the decoder
            uint256(0) // message length (0)
        );
    }

    /// @dev Sanity: the hand-built bytes really are (a) non-canonical and
    ///      (b) decode to the same struct / same canonical txId.
    function test_nonCanonicalDecodesToSameTransaction() public view {
        Transaction memory t = _tx(1, CHAIN_ID, "");
        bytes memory canonical = TransactionLib.encode(t);
        bytes memory weird = _nonCanonicalEmptyMessage(t);

        // Different raw bytes...
        assertTrue(keccak256(canonical) != keccak256(weird), "expected non-canonical bytes");

        // ...but decode to the same struct, hence the same canonical id.
        Transaction memory decoded = TransactionLib.decode(weird);
        assertEq(TransactionLib.id(decoded), TransactionLib.id(t));
    }

    /// @dev The record is stored under the CANONICAL hash even when the bridge
    ///      delivered the non-canonical bytes.
    function test_receiveStoresUnderCanonicalId() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        // A single-word message is not a valid `Action[]`, so execution fails
        // and the record settles as `Delivered` -- which is exactly the state
        // whose bytes an operator must be able to cancel/retry. What matters
        // here is only WHICH id it is stored under.
        Transaction memory t = _txDeliverable(1);
        bytes memory weird = _nonCanonical(t);

        vm.prank(address(adapterA));
        bytes32 returnedId = controller.receiveMessage(1, weird, CHAIN_ID);

        // Stored under the CANONICAL id, not the hash of the delivered bytes.
        assertEq(returnedId, TransactionLib.id(t));
        assertTrue(TransactionLib.id(t) != keccak256(weird), "canonical id must differ from raw-bytes hash");
        assertEq(uint256(controller.getTransactionState(TransactionLib.id(t))), uint256(TransactionState.Delivered));
    }

    /// @dev THE FIX: a message delivered as non-canonical bytes and left
    ///      `Delivered` is still reachable by `cancelMessage`. Since cancelling
    ///      takes the txId directly, the encoding it arrived in is irrelevant:
    ///      the canonical id resolves the record either way.
    function test_cancelAcceptsMessageDeliveredAsNonCanonicalBytes() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        // A payload that is decodable but not a valid Action[] leaves the
        // message `Delivered` (executeActions reverts on decode).
        Transaction memory t = _txDeliverable(1);
        bytes memory weird = _nonCanonical(t);
        bytes32 canonicalId = TransactionLib.id(t);

        vm.prank(address(adapterA));
        controller.receiveMessage(1, weird, CHAIN_ID);
        assertEq(uint256(controller.getTransactionState(canonicalId)), uint256(TransactionState.Delivered));

        // Cancel by the canonical id, though the bytes delivered were not.
        vm.prank(alice);
        controller.cancelMessage(canonicalId);

        assertEq(uint256(controller.getTransactionState(canonicalId)), uint256(TransactionState.Cancelled));
    }

    /// @dev Mirror of the above for the retry path: retrying with the
    ///      non-canonical bytes resolves to the same stored record.
    function test_retryAcceptsNonCanonicalBytes() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        Transaction memory t = _txDeliverable(1);
        bytes memory weird = _nonCanonical(t);
        bytes32 canonicalId = TransactionLib.id(t);

        vm.prank(address(adapterA));
        controller.receiveMessage(1, weird, CHAIN_ID);
        assertEq(uint256(controller.getTransactionState(canonicalId)), uint256(TransactionState.Delivered));

        // Retry with the non-canonical bytes still fails to execute (payload is
        // undecodable as Action[]), so it reverts — but crucially NOT with
        // "not exists": it found the record.
        vm.expectRevert();
        vm.prank(alice);
        controller.retryMessage(weird);

        // Record is untouched and still findable by canonical bytes.
        assertEq(uint256(controller.getTransactionState(canonicalId)), uint256(TransactionState.Delivered));
    }

    // -------------------------------------------------------------------------
    // Helpers for a `Delivered` (execution-failing) message with arbitrary
    // message bytes, plus a general non-canonical encoder.
    // -------------------------------------------------------------------------

    /// @dev A transaction whose `message` is non-empty but is NOT a valid
    ///      `Action[]` encoding, so `executeActions` reverts on decode and the
    ///      message settles as `Delivered`. Message is a single 32-byte word to
    ///      keep the non-canonical encoder simple.
    function _txDeliverable(uint256 _nonce) internal view returns (Transaction memory) {
        return _tx(_nonce, CHAIN_ID, hex"00000000000000000000000000000000000000000000000000000000deadbeef");
    }

    /// @dev Non-canonical encoding for a transaction with a single-word message
    ///      (0x20 bytes). Same trick as the empty-message helper: bump the
    ///      message offset one word and splice garbage into the gap.
    function _nonCanonical(Transaction memory _t) internal pure returns (bytes memory) {
        require(_t.message.length == 32, "helper assumes 32-byte message");

        return abi.encodePacked(
            uint256(0x20), // top-level offset to the tuple
            _t.nonce,
            uint256(uint160(_t.origin)),
            uint256(uint160(_t.controller)),
            _t.originChainId,
            _t.destinationChainId,
            uint256(0xe0), // message offset, bumped from canonical 0xc0
            uint256(0xdeadbeef), // garbage word in the gap
            uint256(_t.message.length), // message length (32)
            _t.message // message data
        );
    }
}
