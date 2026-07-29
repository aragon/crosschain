// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";

/// @title TransactionLibTest
/// @notice Direct tests of the envelope library itself. The controller mixes
///         the two `id` overloads across the send and receive paths, so their
///         equivalence -- and the encode/decode round-trip -- are load-bearing
///         for message delivery, not implementation details.
contract TransactionLibTest is Test {
    function _sample() internal pure returns (Transaction memory) {
        return Transaction({
            nonce: 7,
            origin: address(0x1111),
            controller: address(0x2222),
            originChainId: 10,
            destinationChainId: 137,
            message: hex"deadbeef"
        });
    }

    // -------------------------------------------------------------------------
    // encode/decode round-trip.
    // -------------------------------------------------------------------------

    /// @dev Field-by-field, not id-by-id: a hash comparison could not tell a
    ///      correct round-trip from one that swapped the two adjacent address
    ///      fields (`origin`/`controller`) in a future struct reordering.
    function test_decodeOfEncodeRoundTripsEveryField() public pure {
        Transaction memory original = _sample();

        Transaction memory decoded = TransactionLib.decode(TransactionLib.encode(original));

        assertEq(decoded.nonce, original.nonce);
        assertEq(decoded.origin, original.origin);
        assertEq(decoded.controller, original.controller);
        assertEq(decoded.originChainId, original.originChainId);
        assertEq(decoded.destinationChainId, original.destinationChainId);
        assertEq(decoded.message, original.message);
    }

    function test_roundTripPreservesEmptyMessage() public pure {
        Transaction memory original = _sample();
        original.message = "";

        Transaction memory decoded = TransactionLib.decode(TransactionLib.encode(original));

        assertEq(decoded.message, bytes(""));
        assertEq(TransactionLib.id(decoded), TransactionLib.id(original));
    }

    // -------------------------------------------------------------------------
    // The two `id` overloads must agree.
    // -------------------------------------------------------------------------

    /// @dev `forwardMessage` derives the txId from the BYTES overload
    ///      (`encodedTx.id()`), while `receiveMessage`/`retryMessage`/
    ///      `cancelMessage` derive it from the STRUCT overload
    ///      (`transaction.id()`). If the two ever diverged, every forwarded
    ///      message would arrive under a different txId than it was sent with.
    function test_idOfStructEqualsIdOfItsEncoding() public pure {
        Transaction memory transaction = _sample();

        assertEq(
            TransactionLib.id(transaction),
            TransactionLib.id(TransactionLib.encode(transaction)),
            "struct-id and bytes-id must agree for the same transaction"
        );
    }

    // -------------------------------------------------------------------------
    // Every field is committed to by the id.
    // -------------------------------------------------------------------------

    /// @dev One mutation per field; each must produce a different id. In
    ///      particular `controller` exists specifically so a re-deployed
    ///      controller cannot collide with the old one's txIds, and
    ///      `origin`/`controller` are adjacent address fields whose swap must
    ///      not be id-neutral.
    function test_idCommitsToEveryField() public pure {
        Transaction memory base = _sample();
        bytes32 baseId = TransactionLib.id(base);

        Transaction memory mutated = _sample();
        mutated.nonce = base.nonce + 1;
        assertTrue(TransactionLib.id(mutated) != baseId, "nonce not committed");

        mutated = _sample();
        mutated.origin = address(0x3333);
        assertTrue(TransactionLib.id(mutated) != baseId, "origin not committed");

        mutated = _sample();
        mutated.controller = address(0x4444);
        assertTrue(TransactionLib.id(mutated) != baseId, "controller not committed");

        mutated = _sample();
        mutated.originChainId = base.originChainId + 1;
        assertTrue(TransactionLib.id(mutated) != baseId, "originChainId not committed");

        mutated = _sample();
        mutated.destinationChainId = base.destinationChainId + 1;
        assertTrue(TransactionLib.id(mutated) != baseId, "destinationChainId not committed");

        mutated = _sample();
        mutated.message = hex"deadbeee";
        assertTrue(TransactionLib.id(mutated) != baseId, "message not committed");
    }

    /// @dev Swapping the two adjacent address fields must change the id --
    ///      the exact confusion an id-only round-trip test could never catch.
    function test_idDistinguishesSwappedOriginAndController() public pure {
        Transaction memory swapped = _sample();
        (swapped.origin, swapped.controller) = (swapped.controller, swapped.origin);

        assertTrue(TransactionLib.id(swapped) != TransactionLib.id(_sample()));
    }

    function test_idIsDeterministic() public pure {
        assertEq(TransactionLib.id(_sample()), TransactionLib.id(_sample()));
        assertEq(TransactionLib.encode(_sample()), TransactionLib.encode(_sample()));
    }
}
