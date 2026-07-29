// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Transaction, TransactionState, TransactionLib } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { ActionExecute } from "@osx-test/mocks/commons/executors/ActionExecute.sol";
import { FlakyTarget } from "@mocks/FlakyTarget.sol";

contract CrossChainControllerRetryMessageTest is CrossChainControllerBase {
    function test_revertsIfCallerUnauthorized() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        (Transaction memory failedTx,) = _causeFailure(60);

        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), bob, retryMessagePermissionId
            )
        );
        vm.prank(bob);
        controller.retryMessage(TransactionLib.encode(failedTx));
    }

    function test_revertsForUnknownTransaction() public {
        // A transaction that was never delivered has state `None`, so retry
        // rejects it (only `Delivered` transactions can be retried).
        Transaction memory unknownTx = _tx(999, CHAIN_ID, _emptyActionsPayload());
        bytes32 txId = TransactionLib.id(unknownTx);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        controller.retryMessage(TransactionLib.encode(unknownTx));
    }

    function test_succeedsOnceFailureConditionRemoved() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        FlakyTarget flaky = new FlakyTarget();
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(flaky), value: 0, data: abi.encodeCall(FlakyTarget.maybeRevert, ()) });
        bytes memory message = abi.encode(actions);
        Transaction memory failedTx = _tx(61, CHAIN_ID, message);
        bytes32 txId = TransactionLib.id(failedTx);

        vm.prank(address(adapterA));
        controller.receiveMessage(61, TransactionLib.encode(failedTx), CHAIN_ID);
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered));

        // Fix the failure condition.
        flaky.setShouldRevert(false);

        vm.expectEmit(true, false, false, false, address(controller));
        emit MessageRetried(txId);

        vm.prank(alice);
        controller.retryMessage(TransactionLib.encode(failedTx));

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertTrue(flaky.wasCalled());
    }

    /// @dev Delivers a message whose payload always fails, leaving the
    ///      transaction stored as `Delivered`. Returns the envelope (needed to
    ///      retry) and its txId.
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
