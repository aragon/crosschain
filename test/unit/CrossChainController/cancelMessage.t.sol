// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Transaction, TransactionState, TransactionLib } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { ActionExecute } from "@osx-test/mocks/commons/executors/ActionExecute.sol";

contract CrossChainControllerCancelMessageTest is CrossChainControllerBase {
    function test_revertsIfCallerUnauthorized() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        (Transaction memory failedTx,) = _causeFailure(70);

        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), bob, cancelMessagePermissionId
            )
        );
        vm.prank(bob);
        controller.cancelMessage(TransactionLib.encode(failedTx));
    }

    function test_revertsForTransactionThatWasNeverDelivered() public {
        // Never delivered -> state `None`, so it is not cancellable.
        Transaction memory unknownTx = _tx(999, CHAIN_ID, _emptyActionsPayload());
        bytes32 txId = TransactionLib.id(unknownTx);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(unknownTx));
    }

    function test_cancelsDeliveredMessageAndSetsStateCancelled() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        (Transaction memory failedTx, bytes32 txId) = _causeFailure(71);

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered));

        vm.expectEmit(true, false, false, false, address(controller));
        emit MessageCancelled(txId);

        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(failedTx));

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Cancelled));
    }

    /// @dev Cancel is terminal: once cancelled, the same message can
    ///      neither be retried nor re-delivered.
    function test_cannotRetryAfterCancel() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        (Transaction memory failedTx, bytes32 txId) = _causeFailure(72);

        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(failedTx));

        // Retry now rejects it: state is `Cancelled`, not `Delivered`.
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        controller.retryMessage(TransactionLib.encode(failedTx));
    }

    /// @dev A cancelled txId can never be re-delivered by the bridge either.
    function test_cannotRedeliverAfterCancel() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        (Transaction memory failedTx, bytes32 txId) = _causeFailure(73);

        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(failedTx));

        // The local adapter redelivering the same envelope must revert: the
        // dedup guard rejects any state other than `None`.
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_DELIVERED_OR_EXECUTED.selector, txId));
        vm.prank(address(adapterA));
        controller.receiveMessage(73, TransactionLib.encode(failedTx), CHAIN_ID);
    }

    function test_revertsWhenCancellingAnExecutedMessage() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        // Deliver a message that executes successfully -> state `Executed`.
        bytes memory message = _emptyActionsPayload();
        Transaction memory okTx = _tx(74, CHAIN_ID, message);
        bytes32 txId = TransactionLib.id(okTx);

        vm.prank(address(adapterA));
        controller.receiveMessage(74, TransactionLib.encode(okTx), CHAIN_ID);
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed));

        // An executed message is not cancellable.
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(okTx));
    }

    function test_cutoffBlockedMessageIsStillCancellable() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        vm.warp(1_000_000);
        (Transaction memory failedTx, bytes32 txId) = _causeFailure(75);

        // Cutoff at exactly `bridgedAt`: retry is blocked from here on.
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, uint120(1_000_000));

        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(failedTx));

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Cancelled));
    }

    function _causeFailure(uint256 _nonce) internal returns (Transaction memory failedTx, bytes32 txId) {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(actionTarget), value: 0, data: abi.encodeCall(ActionExecute.fail, ()) });
        bytes memory message = abi.encode(actions);
        failedTx = _tx(_nonce, CHAIN_ID, message);
        txId = TransactionLib.id(failedTx);

        vm.prank(address(adapterA));
        controller.receiveMessage(_nonce, TransactionLib.encode(failedTx), CHAIN_ID);
    }
}
