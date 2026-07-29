// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Transaction, TransactionState, TransactionLib } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { AdapterMock } from "@mocks/AdapterMock.sol";
import { CounterTarget } from "@mocks/CounterTarget.sol";
import { ReentrantAdapterMock } from "@mocks/ReentrantAdapterMock.sol";
import { ActionExecute } from "@osx-test/mocks/commons/executors/ActionExecute.sol";

contract CrossChainControllerReceiveMessageTest is CrossChainControllerBase {
    // -------------------------------------------------------------------------
    // Inbound authentication.
    // -------------------------------------------------------------------------

    function test_revertsForCallerNotLocalAdapter() public {
        address random = makeAddr("random");
        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, random));
        vm.prank(random);
        controller.receiveMessage(1, _encodedEmptyTx(1, CHAIN_ID), CHAIN_ID);
    }

    function test_revertsForUnregisteredContract() public {
        // A deployed contract that was never configured as a lane's local
        // adapter is just as unauthorized as an EOA.
        AdapterMock strangerAdapter =
            new AdapterMock(address(controller), address(0), 0, bytes32(0), feeSinkA, false, false);
        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, address(strangerAdapter)));
        vm.prank(address(strangerAdapter));
        controller.receiveMessage(1, _encodedEmptyTx(1, CHAIN_ID), CHAIN_ID);
    }

    // -------------------------------------------------------------------------
    // "Don't fully trust the adapter/bridge": the envelope's own chain ids must
    // agree with the delivery, or the message is rejected outright.
    // -------------------------------------------------------------------------

    /// @dev A registered adapter (or the bridge behind it) claiming origin
    ///      chain A while the envelope commits to origin chain B must be
    ///      rejected: the claimed origin decides which lane's trust applies.
    function test_revertsIfEnvelopeOriginChainDiffersFromClaimedOrigin() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        // Envelope committed to OTHER_CHAIN_ID, delivered as if from CHAIN_ID.
        bytes memory encodedTx = _encodedEmptyTx(1, OTHER_CHAIN_ID);

        vm.expectRevert(Errors.INCORRECT_CHAIN_MISMATCH.selector);
        vm.prank(address(adapterA));
        controller.receiveMessage(1, encodedTx, CHAIN_ID);
    }

    /// @dev An envelope addressed to a DIFFERENT destination chain must not
    ///      execute here, even if origin and adapter check out -- this is the
    ///      replay guard against a message being mirrored onto the wrong chain.
    function test_revertsIfEnvelopeDestinationIsNotThisChain() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        // Origin matches the claim; only the destination is foreign. The Base
        // `_tx` helper hardcodes the CORRECT destination, so build it by hand.
        Transaction memory transaction = Transaction({
            nonce: 1,
            origin: address(this),
            controller: address(this),
            originChainId: CHAIN_ID,
            destinationChainId: block.chainid + 1,
            message: _emptyActionsPayload()
        });

        vm.expectRevert(Errors.INCORRECT_CHAIN_MISMATCH.selector);
        vm.prank(address(adapterA));
        controller.receiveMessage(1, TransactionLib.encode(transaction), CHAIN_ID);
    }

    /// @dev A rejected mismatching envelope must leave NO record behind: its
    ///      txId stays `None`, so a later legitimate delivery of the same
    ///      envelope (through the right lane) is not blocked.
    function test_chainMismatchLeavesNoTransactionRecord() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        _configureLane(OTHER_CHAIN_ID, address(adapterB), remoteAdapterB);

        bytes memory encodedTx = _encodedEmptyTx(1, OTHER_CHAIN_ID);
        bytes32 txId = _txId(1, OTHER_CHAIN_ID, _emptyActionsPayload());

        vm.expectRevert(Errors.INCORRECT_CHAIN_MISMATCH.selector);
        vm.prank(address(adapterA));
        controller.receiveMessage(1, encodedTx, CHAIN_ID);

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.None));

        // The same envelope through the RIGHT lane still delivers.
        vm.prank(address(adapterB));
        controller.receiveMessage(1, encodedTx, OTHER_CHAIN_ID);
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed));
    }

    function test_succeedsForRegisteredLocalAdapter() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.prank(address(adapterA));
        bytes32 txId = controller.receiveMessage(42, _encodedEmptyTx(1, CHAIN_ID), CHAIN_ID);

        assertEq(txId, _txId(1, CHAIN_ID, _emptyActionsPayload()));
    }

    function test_revertsIfMessageAlreadyDeliveredOrExecuted() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(actionTarget), value: 0, data: abi.encodeCall(ActionExecute.fail, ()) });
        bytes memory message = abi.encode(actions);
        bytes memory encodedTx = _encodedTx(7, CHAIN_ID, message);
        bytes32 txId = _txId(7, CHAIN_ID, message);

        // First delivery fails execution and is stored as `Delivered`.
        vm.prank(address(adapterA));
        controller.receiveMessage(7, encodedTx, CHAIN_ID);
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered));

        // Redelivering the same envelope (same txId) must revert, not
        // overwrite/duplicate it -- regardless of the bridge messageId.
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_DELIVERED_OR_EXECUTED.selector, txId));
        vm.prank(address(adapterA));
        controller.receiveMessage(8, encodedTx, CHAIN_ID);
    }

    function test_sameEnvelopeWithNewNonceSucceeds() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        CounterTarget counter = new CounterTarget();
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });
        bytes memory message = abi.encode(actions);

        // First delivery, nonce 1.
        bytes memory encodedTx1 = _encodedTx(1, CHAIN_ID, message);
        bytes32 txId1 = _txId(1, CHAIN_ID, message);

        vm.prank(address(adapterA));
        bytes32 returned1 = controller.receiveMessage(1, encodedTx1, CHAIN_ID);

        assertEq(returned1, txId1);
        assertEq(uint256(controller.getTransaction(txId1).state), uint256(TransactionState.Executed));
        assertEq(counter.count(), 1);

        // Second delivery: EVERYTHING identical except nonce (1 -> 2). The
        // whole-struct id therefore differs, so this is a fresh message and
        // must NOT hit MESSAGE_ALREADY_DELIVERED_OR_EXECUTED.
        bytes memory encodedTx2 = _encodedTx(2, CHAIN_ID, message);
        bytes32 txId2 = _txId(2, CHAIN_ID, message);
        assertTrue(txId2 != txId1);

        vm.prank(address(adapterA));
        bytes32 returned2 = controller.receiveMessage(
            1, // even the bridge messageId is reused: irrelevant
            encodedTx2,
            CHAIN_ID
        );

        assertEq(returned2, txId2);
        assertEq(uint256(controller.getTransaction(txId2).state), uint256(TransactionState.Executed));
        // The action ran a second time.
        assertEq(counter.count(), 2);
    }

    /// @dev An adapter registered for chain A may not deliver messages
    ///      claiming chain B: `onlyLocalAdapter` is keyed by the CLAIMED
    ///      origin, so being registered somewhere is not being registered
    ///      everywhere.
    function test_revertsForAdapterClaimingAForeignLane() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, address(adapterA)));
        vm.prank(address(adapterA));
        controller.receiveMessage(1, _encodedEmptyTx(1, OTHER_CHAIN_ID), OTHER_CHAIN_ID);
    }

    function test_emitsMessageReceivedWithFullPayloadOnSuccess() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        uint256 messageId = 42;
        bytes memory encodedTx = _encodedEmptyTx(1, CHAIN_ID);
        bytes32 expectedTxId = _txId(1, CHAIN_ID, _emptyActionsPayload());

        vm.expectEmit(true, true, true, true, address(controller));
        emit MessageReceived(CHAIN_ID, messageId, expectedTxId, encodedTx);

        vm.prank(address(adapterA));
        controller.receiveMessage(messageId, encodedTx, CHAIN_ID);
    }

    /// @dev `bridgedAt` is stamped on BOTH branches: it records arrival, not
    ///      execution success, because the retry cutoff compares against it.
    function test_stampsBridgedAtOnSuccessAndFailureAlike() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        vm.warp(123_456);

        // Success branch.
        vm.prank(address(adapterA));
        bytes32 okTxId = controller.receiveMessage(1, _encodedEmptyTx(1, CHAIN_ID), CHAIN_ID);
        assertEq(controller.getTransaction(okTxId).bridgedAt, uint120(123_456));

        // Failure branch.
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(actionTarget), value: 0, data: abi.encodeCall(ActionExecute.fail, ()) });
        bytes memory message = abi.encode(actions);
        vm.prank(address(adapterA));
        bytes32 failedTxId = controller.receiveMessage(2, _encodedTx(2, CHAIN_ID, message), CHAIN_ID);
        assertEq(controller.getTransaction(failedTxId).bridgedAt, uint120(123_456));
    }

    function test_revertsOnUndecodableOuterEnvelope() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.expectRevert();
        vm.prank(address(adapterA));
        controller.receiveMessage(1, hex"01", CHAIN_ID);
    }

    function test_reentrantRedeliveryDuringExecutionIsRejected() public {
        ReentrantAdapterMock reentrantAdapter = new ReentrantAdapterMock(address(controller));
        _configureLane(CHAIN_ID, address(reentrantAdapter), remoteAdapterA);

        Action[] memory actions = new Action[](1);
        actions[0] =
            Action({ to: address(reentrantAdapter), value: 0, data: abi.encodeCall(ReentrantAdapterMock.reenter, ()) });
        bytes memory message = abi.encode(actions);
        bytes memory encodedTx = _encodedTx(80, CHAIN_ID, message);
        bytes32 txId = _txId(80, CHAIN_ID, message);

        reentrantAdapter.prime(encodedTx, CHAIN_ID);

        vm.prank(address(reentrantAdapter));
        controller.receiveMessage(80, encodedTx, CHAIN_ID);

        assertFalse(reentrantAdapter.reentrySucceeded(), "the reentrant redelivery must not have executed");
        assertEq(
            reentrantAdapter.reentryRevertData(),
            abi.encodeWithSelector(Errors.MESSAGE_ALREADY_DELIVERED_OR_EXECUTED.selector, txId),
            "the inner delivery must have hit the dedup guard"
        );
        // The outer delivery itself completed normally.
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed));
    }

    function test_capturesRevertingPayloadInsteadOfReverting() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(actionTarget), value: 0, data: abi.encodeCall(ActionExecute.fail, ()) });
        bytes memory message = abi.encode(actions);
        bytes memory encodedTx = _encodedTx(55, CHAIN_ID, message);

        uint256 messageId = 55;
        bytes32 expectedTxId = _txId(55, CHAIN_ID, message);
        // `CrossChainControllerDAOMock.execute` bubbles the low-level call's
        // raw returndata on failure, which is `ActionExecute.fail`'s
        // `Error(string)`-encoded revert reason.
        bytes memory expectedReason = abi.encodeWithSignature("Error(string)", "ActionExecute:Revert");

        vm.expectEmit(true, true, true, true, address(controller));
        emit MessageExecutionFailed(CHAIN_ID, messageId, expectedTxId, encodedTx, expectedReason);

        vm.prank(address(adapterA));
        bytes32 txId = controller.receiveMessage(messageId, encodedTx, CHAIN_ID); // must NOT revert
        assertEq(txId, expectedTxId);

        // A failed execution is stored as `Delivered` (awaiting retry).
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered));
    }

    function test_acceptsPlainNativeTransfer() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(controller).call{ value: 1 ether }("");

        assertTrue(ok, "a plain empty-calldata transfer must be accepted");
        assertEq(address(controller).balance, 1 ether);
    }

    function test_capturesMalformedInnerPayloadInsteadOfReverting() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        bytes memory garbageMessage = hex"deadbeef";
        bytes memory encodedTx = _encodedTx(56, CHAIN_ID, garbageMessage);

        uint256 messageId = 56;
        bytes32 expectedTxId = _txId(56, CHAIN_ID, garbageMessage);

        // Only check the indexed topics here (origin/message/tx id); the
        // non-indexed data (envelope + the exact revert bytes produced by a
        // failed `abi.decode`) is an implementation/compiler detail we don't
        // want to pin, so `checkData` is false and these values are ignored.
        vm.expectEmit(true, true, true, false, address(controller));
        emit MessageExecutionFailed(CHAIN_ID, messageId, expectedTxId, "", "");

        vm.prank(address(adapterA));
        bytes32 txId = controller.receiveMessage(messageId, encodedTx, CHAIN_ID); // must NOT revert
        assertEq(txId, expectedTxId);
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered));
    }
}
