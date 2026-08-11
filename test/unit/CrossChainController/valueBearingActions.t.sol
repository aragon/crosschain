// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { Executor } from "@src/Executor.sol";
import { Executor as CommonsExecutor } from "@aragon/osx-commons-contracts/src/executors/Executor.sol";
import { Errors } from "@src/lib/Errors.sol";
import { TransactionState } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { CounterTarget } from "@mocks/CounterTarget.sol";
import { ValueReceiverTarget } from "@mocks/ValueReceiverTarget.sol";

/// @title CrossChainControllerValueBearingActionsTest
/// @notice Pins the end-to-end behaviour of an inbound message whose `Action[]`
///         carries `value > 0`.
///
/// @dev The spec's claim (SPEC.md, "Value-bearing actions") is that the
///      messaging layer moves instructions and never funds: the whole receive
///      path is non-payable, so the native currency an action spends can only
///      come from the EXECUTOR's own pre-funded balance -- never from the
///      message, and never from the controller's bridge-fee float. These tests
///      exercise that on both execution targets the system supports: the
///      standalone `Executor` (owned by the controller) and `executor == dao`.
contract CrossChainControllerValueBearingActionsTest is CrossChainControllerBase {
    /// @dev A second controller wired to the standalone `Executor` instead of
    ///      the DAO, so the executor's balance is distinct from the DAO's.
    CrossChainController internal execController;
    Executor internal standaloneExecutor;

    ValueReceiverTarget internal valueTarget;
    CounterTarget internal counterTarget;
    address payable internal recipient;

    function setUp() public virtual override {
        super.setUp();

        valueTarget = new ValueReceiverTarget();
        counterTarget = new CounterTarget();
        recipient = payable(makeAddr("valueRecipient"));

        standaloneExecutor = new Executor();
        execController = deployController(address(daoMock), address(standaloneExecutor));
        standaloneExecutor.transferOwnership(address(execController));

        daoMock.setHasPermission(address(execController), alice, manageConfigPermissionId, true);
        daoMock.setHasPermission(address(execController), alice, retryMessagePermissionId, true);
        daoMock.setHasPermission(address(execController), alice, cancelMessagePermissionId, true);

        // Same lane on both controllers. `receiveMessage` only checks that the
        // caller is the registered local adapter, so the mock can be pranked
        // for either controller.
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        _configureLaneOn(execController, CHAIN_ID, address(adapterA), remoteAdapterA);
    }

    // -------------------------------------------------------------------------
    // Helpers.
    // -------------------------------------------------------------------------

    function _configureLaneOn(CrossChainController _controller, uint256 _chainId, address _local, address _remote)
        internal
    {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = _chainId;
        CrossChainController.ChainConfig[] memory configs = new CrossChainController.ChainConfig[](1);
        configs[0] = _lane(_local, _remote);

        vm.prank(alice);
        _controller.updateConfig(chainIds, configs);
    }

    function _valueAction(address _to, uint256 _value) internal pure returns (Action[] memory actions) {
        actions = new Action[](1);
        actions[0] = Action({ to: _to, value: _value, data: "" });
    }

    /// @dev Delivers `_actions` to `_controller` through the registered adapter
    ///      and returns the envelope bytes plus the txId, so a follow-up retry
    ///      or cancel can address the same message.
    function _deliver(CrossChainController _controller, uint256 _nonce, Action[] memory _actions)
        internal
        returns (bytes memory encodedTx, bytes32 txId)
    {
        bytes memory message = abi.encode(_actions);
        encodedTx = _encodedTx(_nonce, CHAIN_ID, message);
        txId = _txId(_nonce, CHAIN_ID, message);

        vm.prank(address(adapterA));
        _controller.receiveMessage(_nonce, encodedTx, CHAIN_ID);
    }

    // -------------------------------------------------------------------------
    // Where the money comes from.
    // -------------------------------------------------------------------------

    /// @dev The headline behaviour: a funded executor forwards `action.value`
    ///      out of its OWN balance, and the controller's native float (the
    ///      bridge-fee pre-funding accepted by `receive()`) is not touched.
    function test_valueIsPaidFromExecutorBalanceAndControllerFloatIsUntouched() public {
        vm.deal(address(standaloneExecutor), 1 ether);
        vm.deal(address(execController), 5 ether);

        (, bytes32 txId) = _deliver(execController, 1, _valueAction(recipient, 1 ether));

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Executed));
        assertEq(recipient.balance, 1 ether, "recipient must be paid from the executor");
        assertEq(address(standaloneExecutor).balance, 0, "executor balance is the source of funds");
        assertEq(
            address(execController).balance, 5 ether, "the controller's fee float must not be spendable by actions"
        );
    }

    /// @dev On the `executor == dao` wiring (the default the fixture uses) the
    ///      same value comes out of the DAO's balance instead.
    function test_daoExecutorPaysValueFromDaoBalance() public {
        vm.deal(address(daoMock), 1 ether);
        vm.deal(address(controller), 5 ether);

        (, bytes32 txId) = _deliver(controller, 1, _valueAction(recipient, 1 ether));

        assertEq(uint256(controller.getTransactionState(txId)), uint256(TransactionState.Executed));
        assertEq(recipient.balance, 1 ether);
        assertEq(address(daoMock).balance, 0);
        assertEq(address(controller).balance, 5 ether);
    }

    /// @dev The target observes exactly `action.value` as `msg.value` -- the
    ///      message itself contributes nothing.
    function test_targetObservesExactlyTheActionValue() public {
        vm.deal(address(standaloneExecutor), 3 ether);

        Action[] memory actions = new Action[](1);
        actions[0] =
            Action({ to: address(valueTarget), value: 2 ether, data: abi.encodeCall(ValueReceiverTarget.pay, ()) });

        _deliver(execController, 1, actions);

        assertEq(valueTarget.lastValue(), 2 ether);
        assertEq(valueTarget.calls(), 1);
        assertEq(address(standaloneExecutor).balance, 1 ether, "only the action's value leaves the executor");
    }

    /// @dev A zero-value action moves nothing, even from a funded executor.
    function test_zeroValueActionMovesNothing() public {
        vm.deal(address(standaloneExecutor), 1 ether);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counterTarget), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });

        _deliver(execController, 1, actions);

        assertEq(counterTarget.count(), 1);
        assertEq(address(standaloneExecutor).balance, 1 ether);
    }

    // -------------------------------------------------------------------------
    // Underfunded: captured for retry, not lost.
    // -------------------------------------------------------------------------

    /// @dev The spec's recovery loop, full path: an underfunded value action
    ///      fails, the zero `allowFailureMap` reverts the batch, the delivery
    ///      is still recorded as `Delivered`, and a retry after funding pays.
    function test_underfundedValueActionIsCapturedAsDeliveredThenPaidOnRetry() public {
        (bytes memory encodedTx, bytes32 txId) = _deliver(execController, 1, _valueAction(recipient, 1 ether));

        assertEq(
            uint256(execController.getTransactionState(txId)),
            uint256(TransactionState.Delivered),
            "an underfunded action must not revert the delivery"
        );
        assertEq(recipient.balance, 0);

        // Funding is a separate, prior operation -- never part of the message.
        vm.deal(address(standaloneExecutor), 1 ether);

        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Executed));
        assertEq(recipient.balance, 1 ether);
        assertEq(address(standaloneExecutor).balance, 0);
    }

    /// @dev The `MessageExecutionFailed` reason for an underfunded value action
    ///      is the executor's own `ActionFailed(index)`.
    function test_underfundedValueActionSurfacesActionFailedReason() public {
        bytes memory message = abi.encode(_valueAction(recipient, 1 ether));
        bytes memory encodedTx = _encodedTx(9, CHAIN_ID, message);
        bytes32 expectedTxId = _txId(9, CHAIN_ID, message);
        bytes memory expectedReason = abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0));

        vm.expectEmit(true, true, true, true, address(execController));
        emit MessageExecutionFailed(CHAIN_ID, 9, expectedTxId, encodedTx, expectedReason);

        vm.prank(address(adapterA));
        execController.receiveMessage(9, encodedTx, CHAIN_ID);
    }

    /// @dev A retry that is STILL underfunded reverts and leaves the message
    ///      `Delivered`, so it stays retryable rather than being burned.
    function test_retryOfStillUnderfundedMessageRevertsAndKeepsItRetryable() public {
        (bytes memory encodedTx, bytes32 txId) = _deliver(execController, 1, _valueAction(recipient, 1 ether));

        // Short by 1 wei.
        vm.deal(address(standaloneExecutor), 1 ether - 1);

        vm.expectRevert(abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0)));
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Delivered));

        vm.deal(address(standaloneExecutor), 1 ether);
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Executed));
        assertEq(recipient.balance, 1 ether);
    }

    /// @dev A message that will never be funded can be cancelled, permanently
    ///      occupying its txId.
    function test_unfundableValueMessageCanBeCancelled() public {
        (bytes memory encodedTx, bytes32 txId) = _deliver(execController, 1, _valueAction(recipient, 1 ether));

        vm.prank(alice);
        execController.cancelMessage(txId);

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Cancelled));

        vm.deal(address(standaloneExecutor), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(recipient.balance, 0);
    }

    // -------------------------------------------------------------------------
    // Atomicity and hostile targets.
    // -------------------------------------------------------------------------

    /// @dev `allowFailureMap` is hardcoded to `0`, so a batch that runs out of
    ///      funds midway is rolled back whole -- the earlier transfer does not
    ///      stick.
    function test_partiallyFundedBatchIsRolledBackWhole() public {
        vm.deal(address(standaloneExecutor), 1 ether);

        Action[] memory actions = new Action[](2);
        actions[0] = Action({ to: recipient, value: 1 ether, data: "" });
        actions[1] = Action({ to: address(valueTarget), value: 1 ether, data: "" });

        (, bytes32 txId) = _deliver(execController, 1, actions);

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Delivered));
        assertEq(recipient.balance, 0, "the funded first action must be rolled back with the batch");
        assertEq(address(valueTarget).balance, 0);
        assertEq(address(standaloneExecutor).balance, 1 ether, "the executor keeps every wei");
    }

    /// @dev Sending value to a non-payable function fails the action even with
    ///      a fully funded executor; the message is captured for retry (and
    ///      will keep failing -- it is a payload bug, so cancel is the exit).
    function test_valueToNonPayableTargetIsCapturedAsDelivered() public {
        vm.deal(address(standaloneExecutor), 1 ether);

        Action[] memory actions = new Action[](1);
        actions[0] =
            Action({ to: address(counterTarget), value: 1 ether, data: abi.encodeCall(CounterTarget.increment, ()) });

        (, bytes32 txId) = _deliver(execController, 1, actions);

        assertEq(uint256(execController.getTransactionState(txId)), uint256(TransactionState.Delivered));
        assertEq(counterTarget.count(), 0);
        assertEq(address(standaloneExecutor).balance, 1 ether);
    }

    // -------------------------------------------------------------------------
    // The message can never CARRY value: every entry point is non-payable.
    // -------------------------------------------------------------------------

    function test_receiveMessageRejectsAttachedValue() public {
        vm.deal(address(adapterA), 1 ether);

        bytes memory encodedTx = _encodedEmptyTx(1, CHAIN_ID);
        bytes memory callData = abi.encodeCall(CrossChainController.receiveMessage, (1, encodedTx, CHAIN_ID));

        vm.prank(address(adapterA));
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(execController).call{ value: 1 ether }(callData);

        assertFalse(ok, "receiveMessage is non-payable: value must be rejected");
        assertEq(address(execController).balance, 0);
    }

    function test_forwardMessageRejectsAttachedValue() public {
        vm.deal(alice, 1 ether);

        bytes memory callData =
            abi.encodeCall(CrossChainController.forwardMessage, (CHAIN_ID, GAS_LIMIT, _emptyActionsPayload()));

        vm.prank(alice);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(controller).call{ value: 1 ether }(callData);

        assertFalse(ok, "forwardMessage is non-payable: senders cannot bridge funds with a message");
    }

    function test_retryMessageRejectsAttachedValue() public {
        (bytes memory encodedTx,) = _deliver(execController, 1, _valueAction(recipient, 1 ether));

        vm.deal(alice, 1 ether);
        bytes memory callData = abi.encodeCall(CrossChainController.retryMessage, (encodedTx));

        vm.prank(alice);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = address(execController).call{ value: 1 ether }(callData);

        assertFalse(ok, "retryMessage is non-payable: the retrier cannot fund the action inline");
        assertEq(recipient.balance, 0);
    }
}
