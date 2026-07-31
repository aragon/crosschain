// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { Executor as CommonsExecutor } from "@aragon/osx-commons-contracts/src/executors/Executor.sol";
import { DAO } from "@aragon/osx/core/dao/DAO.sol";

import { ICrossChainController } from "@src/ICrossChainController.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";

import { CrossChainE2EBase } from "./Base.sol";
import { CallerReenterer, GuardedTarget, ValueSink } from "@mocks/E2ETargets.sol";

/// @title CrossChainRetryAndFailuresE2ETest
/// @notice Every way a message can fail after it has been sent, and every way
///         it can be recovered.
///
/// @dev THE TWO LAYERS. This is the least obvious property of the design, and
///      the distinction every test in this file turns on:
///
///      LAYER 2 -- APPLICATION. `receiveMessage` wraps the execution in a
///      `try/catch`. A payload that reverts is CAUGHT: the bridge delivery
///      still succeeds, the transaction is recorded as `Delivered`, and
///      `MessageExecutionFailed` carries the reason. Recovery is
///      `retryMessage`, which needs `RETRY_MESSAGE_PERMISSION`.
///
///      LAYER 1 -- BRIDGE. If `ccipReceive` itself reverts -- a rejected
///      sender, a cleared lane, a rotated adapter, too little gas -- nothing is
///      stored at all. The transaction stays `None` and CCIP marks the message
///      failed but manually executable. Recovery is a CCIP re-execution, which
///      needs no permission from us and works once the cause is fixed.
///
///      Reading the tests: `success` from `_deliver*` is the BRIDGE-level
///      outcome. `success == true` with state `Delivered` is a payload failure;
///      `success == false` with state `None` is a delivery failure.
contract CrossChainRetryAndFailuresE2ETest is CrossChainE2EBase {
    /// @dev Sends a message whose payload will fail, and delivers it. Returns
    ///      the id and the exact envelope bytes needed to retry it.
    function _deliverFailingMessage() internal returns (bytes32 txId, bytes memory encodedTx) {
        destination.target.setLocked(true);

        txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        encodedTx = _queuedPayload(origin, 0);

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the BRIDGE delivery must succeed");
        _assertDelivered(destination, txId);
    }

    // -------------------------------------------------------------------------
    // Layer 2: application-level retry.
    // -------------------------------------------------------------------------

    /// @notice The core failure-then-retry loop: a reverting action is stored,
    ///         the cause is fixed, and ops retries it.
    function test_retry_failedActionIsStoredThenRetriedAfterTheFix() public {
        destination.target.setLocked(true);

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes memory encodedTx = _queuedPayload(origin, 0);
        bytes32 messageId = origin.router.messageIdAt(0);

        _on(destination);
        vm.expectEmit(true, true, true, true, address(destination.controller));
        emit MessageExecutionFailed(
            origin.chainId,
            uint256(messageId),
            txId,
            encodedTx,
            abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0))
        );
        assertTrue(origin.router.deliver(messageId));
        _on(origin);

        _assertDelivered(destination, txId);
        assertEq(destination.target.cancellations(), 0, "the action must not have run");

        // Fix the cause and retry as ops.
        destination.target.setLocked(false);

        _on(destination);
        vm.expectEmit(true, false, false, false, address(destination.controller));
        emit MessageRetried(txId);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1, "the retry must have run");
        assertEq(destination.target.lastCaller(), address(destination.executor));
    }

    /// @notice With `executor = dao`, a DAO that holds `RETRY_MESSAGE_PERMISSION`
    ///         CANNOT USE IT, because the only way a DAO acts is by executing a
    ///         proposal -- and `retryMessage` has to re-enter `DAO.execute`,
    ///         which the DAO's reentrancy guard forbids.
    /// @dev This is the executable form of the warning on
    ///      `Permissions.RETRY_MESSAGE_PERMISSION_ID`: the holder must never be
    ///      the configured executor. `CrossChainControllerSetup` supports
    ///      `executor = dao`, so the trap is reachable in a real deployment; the
    ///      setup grants retry to `ANY_ADDR` precisely so an ordinary EOA can
    ///      call the controller directly instead.
    ///
    ///      ON THE ASSERTION. `DAO.execute` swallows the inner revert reason and
    ///      re-raises `ActionFailed(0)`, so this cannot assert the reentrancy
    ///      guard specifically -- any inner failure produces the same selector.
    ///      What isolates the cause is
    ///      `test_failure_missingExecutePermissionFailsThenRetriesAfterGrant`
    ///      below, which shows this exact wiring retries fine through a direct
    ///      ops call. The caller is then the only variable left between the two.
    function test_retry_daoAsExecutorCannotRetryThroughAProposal() public {
        _useDaoAsExecutor(destination);
        destination.dao
            .grant(address(destination.controller), address(destination.dao), Permissions.RETRY_MESSAGE_PERMISSION_ID);

        (bytes32 txId, bytes memory encodedTx) = _deliverFailingMessage();
        destination.target.setLocked(false);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            to: address(destination.controller),
            value: 0,
            data: abi.encodeCall(ICrossChainController.retryMessage, (encodedTx))
        });

        _on(destination);
        vm.prank(plugin);
        vm.expectRevert(abi.encodeWithSelector(DAO.ActionFailed.selector, uint256(0)));
        destination.dao.execute(keccak256("retry-proposal"), actions, 0);
        _on(origin);

        _assertDelivered(destination, txId);
        assertEq(destination.target.cancellations(), 0);
    }

    /// @notice The retry DOES work when the permission is held by an account
    ///         that calls the controller directly.
    /// @dev The counterpart to the test above: this is the wiring a production
    ///      deployment needs.
    function test_retry_opsAccountHoldingThePermissionCanRetry() public {
        (bytes32 txId, bytes memory encodedTx) = _deliverFailingMessage();
        destination.target.setLocked(false);

        address opsMultisig = makeAddr("opsMultisig");
        destination.dao.grant(address(destination.controller), opsMultisig, Permissions.RETRY_MESSAGE_PERMISSION_ID);

        _on(destination);
        vm.prank(opsMultisig);
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice Retrying needs the permission; the bridge already authenticated
    ///         the payload, but replaying it is still a privileged action.
    function test_retry_requiresTheRetryPermission() public {
        (, bytes memory encodedTx) = _deliverFailingMessage();
        destination.target.setLocked(false);

        _on(destination);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(destination.dao),
                address(destination.controller),
                stranger,
                Permissions.RETRY_MESSAGE_PERMISSION_ID
            )
        );
        destination.controller.retryMessage(encodedTx);
    }

    /// @notice Retrying something that was never delivered is rejected.
    function test_retry_unknownTransactionIsRejected() public {
        bytes memory encodedTx = _encodedTx(origin, destination, 99, address(origin.dao), _cancelPayload(destination));

        _on(destination);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, TransactionLib.id(encodedTx))
        );
        destination.controller.retryMessage(encodedTx);
    }

    /// @notice A transaction that already succeeded cannot be retried.
    function test_retry_alreadyExecutedTransactionIsRejected() public {
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes memory encodedTx = _queuedPayload(origin, 0);

        _deliverNext(origin, destination);
        _assertExecuted(destination, txId);

        _on(destination);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        destination.controller.retryMessage(encodedTx);
    }

    /// @notice A successful retry cannot be replayed: the action runs once.
    function test_retry_cannotBeReplayedAfterSucceeding() public {
        (bytes32 txId, bytes memory encodedTx) = _deliverFailingMessage();
        destination.target.setLocked(false);

        _on(destination);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);
        assertEq(destination.target.cancellations(), 1);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        destination.controller.retryMessage(encodedTx);

        assertEq(destination.target.cancellations(), 1, "the action must run only once");
    }

    /// @notice A retry that fails again leaves the transaction retryable.
    /// @dev `retryMessage` writes `Executed` BEFORE executing. When the
    ///      execution reverts the whole call reverts, so that write is rolled
    ///      back and the state is still `Delivered`. Without that ordering a
    ///      failed retry would burn the message permanently.
    function test_retry_thatFailsAgainStaysRetryable() public {
        (bytes32 txId, bytes memory encodedTx) = _deliverFailingMessage();

        // Still locked: the retry fails.
        _on(destination);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0)));
        destination.controller.retryMessage(encodedTx);

        _assertDelivered(destination, txId);

        // A second retry fails identically.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0)));
        destination.controller.retryMessage(encodedTx);

        _assertDelivered(destination, txId);

        // And once the cause is fixed, the third attempt lands.
        destination.target.setLocked(false);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);

        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice Tampering with the envelope changes its id, so the tampered bytes
    ///         match no stored transaction.
    /// @dev The retry path takes RAW BYTES from the caller and trusts only their
    ///      hash. This is what makes that safe: a retrier holding the permission
    ///      still cannot swap in a different payload.
    function test_retry_tamperedEnvelopeIsRejected() public {
        (, bytes memory encodedTx) = _deliverFailingMessage();
        destination.target.setLocked(false);

        Transaction memory decoded = TransactionLib.decode(encodedTx);

        // Redirect the action at a target the attacker controls.
        GuardedTarget attackerTarget = new GuardedTarget();
        decoded.message = _actionPayload(address(attackerTarget), 0, abi.encodeCall(GuardedTarget.cancelRootUpdate, ()));

        bytes memory tampered = TransactionLib.encode(decoded);

        _on(destination);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, TransactionLib.id(tampered))
        );
        destination.controller.retryMessage(tampered);

        assertEq(attackerTarget.cancellations(), 0, "the swapped-in action must not have run");
    }

    /// @notice Bumping the nonce in the envelope is caught the same way.
    function test_retry_envelopeWithABumpedNonceIsRejected() public {
        (, bytes memory encodedTx) = _deliverFailingMessage();

        Transaction memory decoded = TransactionLib.decode(encodedTx);
        decoded.nonce += 1;
        bytes memory tampered = TransactionLib.encode(decoded);

        _on(destination);
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, TransactionLib.id(tampered))
        );
        destination.controller.retryMessage(tampered);
    }

    /// @notice A bridge-level redelivery cannot bypass the application-level
    ///         retry: a stored `Delivered` transaction rejects a second arrival.
    function test_retry_bridgeRedeliveryOfAStoredMessageIsRejected() public {
        (bytes32 txId, bytes memory encodedTx) = _deliverFailingMessage();

        (bool success, bytes memory reason) = _forgeDelivery(
            destination,
            keccak256("a-second-arrival"),
            ORIGIN_SELECTOR,
            address(origin.controller),
            encodedTx,
            GAS_LIMIT
        );

        assertFalse(success, "redelivery must be rejected");
        assertEq(reason, abi.encodeWithSelector(Errors.MESSAGE_ALREADY_DELIVERED_OR_EXECUTED.selector, txId));
        _assertDelivered(destination, txId);
    }

    /// @notice Cancelling neutralises a failed message for good: the retry path
    ///         refuses it even after the underlying failure is fixed.
    /// @dev The emergency lever. `cancelMessage` is deliberately still available
    ///      while the controller is paused, so a bad message can be neutralised
    ///      mid-incident.
    function test_retry_cancelledMessageCanNeverExecute() public {
        (bytes32 txId, bytes memory encodedTx) = _deliverFailingMessage();

        _on(destination);
        vm.prank(address(destination.dao));
        destination.controller.cancelMessage(encodedTx);
        _assertCancelled(destination, txId);

        // Even with the failure fixed, the message can never run.
        destination.target.setLocked(false);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        // Nor can the bridge redeliver it.
        (bool success,) = _forgeDelivery(
            destination, keccak256("after-cancel"), ORIGIN_SELECTOR, address(origin.controller), encodedTx, GAS_LIMIT
        );

        assertFalse(success, "a cancelled message must not be redeliverable");
        assertEq(destination.target.cancellations(), 0, "a cancelled message must never execute");
    }

    // -------------------------------------------------------------------------
    // Layer 1: bridge-level failure and manual re-execution.
    // -------------------------------------------------------------------------

    /// @notice A lane cleared while a message is in flight rejects it at the
    ///         BRIDGE level -- and the message is not lost: re-configuring the
    ///         lane and re-executing delivers it.
    function test_bridgeRetry_clearedLaneRejectsThenRecoversAfterReconfig() public {
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes32 messageId = origin.router.messageIdAt(0);

        // Ops clears the inbound lane while the message is in flight.
        _clearLane(destination, origin.chainId);

        (, bool success) = _deliverNext(origin, destination);

        assertFalse(success, "delivery must fail at the bridge level");
        _assertUnknown(destination, txId);
        assertEq(destination.target.cancellations(), 0);

        // Nothing was stored, so the message is still cleanly re-executable.
        _configureLane(destination, origin.chainId, address(origin.adapter));

        assertTrue(_manualExecute(origin, destination, messageId, GAS_LIMIT));
        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice The same for an adapter rotation: an in-flight message arrives
    ///         through the OLD adapter, which the controller no longer knows.
    /// @dev The recovery here is to point the lane back. A permanent rotation
    ///      strands in-flight messages until the new adapter can deliver them.
    function test_bridgeRetry_rotatedAdapterRejectsThenRecovers() public {
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes32 messageId = origin.router.messageIdAt(0);

        // Rotate the destination's local adapter to a different contract.
        _configureLaneWithLocalAdapter(
            destination, origin.chainId, address(destination.controller), address(origin.adapter)
        );

        (, bool success) = _deliverNext(origin, destination);

        assertFalse(success, "the old adapter is no longer authorised");
        _assertUnknown(destination, txId);

        // Point the lane back and re-execute.
        _configureLane(destination, origin.chainId, address(origin.adapter));

        assertTrue(_manualExecute(origin, destination, messageId, GAS_LIMIT));
        _assertExecuted(destination, txId);
    }

    // -------------------------------------------------------------------------
    // Execution errors -- every way a delivered payload can fail.
    // -------------------------------------------------------------------------

    /// @notice The stored reason identifies WHICH action of the payload failed.
    /// @dev `Executor.execute` wraps every action revert in `ActionFailed(index)`,
    ///      so the target's own error (here `GuardedTarget.Locked`) never reaches
    ///      the event. What an operator gets instead is the index -- and that is
    ///      the thing worth pinning, because it is what tells them where in a
    ///      multi-action cross-chain proposal the failure was.
    function test_failure_reasonIdentifiesTheFailingActionIndex() public {
        GuardedTarget locked = new GuardedTarget();
        locked.setLocked(true);

        Action[] memory actions = new Action[](3);
        actions[0] = Action({
            to: address(destination.target), value: 0, data: abi.encodeCall(GuardedTarget.cancelRootUpdate, ())
        });
        actions[1] = Action({ to: address(locked), value: 0, data: abi.encodeCall(GuardedTarget.cancelRootUpdate, ()) });
        actions[2] = Action({
            to: address(destination.target), value: 0, data: abi.encodeCall(GuardedTarget.cancelRootUpdate, ())
        });

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, abi.encode(actions));
        bytes memory encodedTx = _queuedPayload(origin, 0);
        bytes32 messageId = origin.router.messageIdAt(0);

        _on(destination);
        vm.expectEmit(true, true, true, true, address(destination.controller));
        emit MessageExecutionFailed(
            origin.chainId,
            uint256(messageId),
            txId,
            encodedTx,
            abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(1))
        );
        assertTrue(origin.router.deliver(messageId));
        _on(origin);

        _assertDelivered(destination, txId);

        // The whole payload is atomic: action 0 rolled back with the rest.
        assertEq(destination.target.cancellations(), 0, "a failed payload must leave no partial effect");
    }

    /// @notice An action pointed at an address with NO CODE is reported as a
    ///         SUCCESS, and the message is marked `Executed`.
    /// @dev A raw `.call` to a codeless address returns true, so `Executor`
    ///      sees no failure. Nothing in the cross-chain path can detect this --
    ///      a cross-chain proposal whose target is mistyped, or not yet deployed
    ///      on the destination, executes to a silent no-op. Worth knowing when
    ///      reviewing cross-chain proposals.
    function test_failure_codelessActionTargetSilentlySucceeds() public {
        address notDeployed = makeAddr("notDeployedOnDestination");
        assertEq(notDeployed.code.length, 0);

        bytes32 txId = _forwardViaProposal(
            origin,
            destination,
            GAS_LIMIT,
            _actionPayload(notDeployed, 0, abi.encodeCall(GuardedTarget.cancelRootUpdate, ()))
        );

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertExecuted(destination, txId);
    }

    /// @notice A payload that is not a valid `Action[]` is CAUGHT, not
    ///         propagated to the bridge.
    /// @dev This is why `abi.decode` lives inside `executeActions` rather than
    ///      in `receiveMessage`: a malformed payload becomes a retryable
    ///      application failure instead of a bridge-level revert.
    function test_failure_malformedPayloadIsCaughtAndStored() public {
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, hex"deadbeef");

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the bridge delivery must still succeed");
        _assertDelivered(destination, txId);
    }

    /// @notice More actions than the executor accepts is likewise caught.
    function test_failure_tooManyActionsIsCaughtAndStored() public {
        bytes32 txId = _forwardViaProposal(origin, destination, 5_000_000, _repeatedCancelPayload(destination, 257));

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertDelivered(destination, txId);
        assertEq(destination.target.cancellations(), 0);
    }

    /// @notice An action needing more value than the destination executor holds
    ///         fails, and succeeds on retry once it is topped up.
    function test_failure_insufficientTreasuryFailsThenRetriesAfterFunding() public {
        ValueSink sink = new ValueSink();

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _actionPayload(address(sink), 5 ether, ""));
        bytes memory encodedTx = _queuedPayload(origin, 0);

        _deliverNext(origin, destination);
        _assertDelivered(destination, txId);
        assertEq(sink.received(), 0);

        vm.deal(address(destination.executor), 5 ether);

        _on(destination);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        _assertExecuted(destination, txId);
        assertEq(sink.received(), 5 ether);
    }

    /// @notice A controller that is no longer the executor's owner stores the
    ///         failure, and the message lands once ownership is handed back.
    /// @dev The standalone-executor analogue of losing `EXECUTE_PERMISSION`: the
    ///      execution target stops accepting orders, and every inbound message
    ///      piles up as `Delivered` rather than being lost.
    function test_failure_lostExecutorOwnershipFailsThenRetriesAfterHandover() public {
        vm.prank(address(destination.controller));
        destination.executor.transferOwnership(stranger);

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes memory encodedTx = _queuedPayload(origin, 0);

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the bridge delivery still succeeds");
        _assertDelivered(destination, txId);

        vm.prank(stranger);
        destination.executor.transferOwnership(address(destination.controller));

        _on(destination);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice With `executor = dao`, a controller without `EXECUTE_PERMISSION`
    ///         on its own DAO stores the failure, and the message lands once the
    ///         grant is made.
    function test_failure_missingExecutePermissionFailsThenRetriesAfterGrant() public {
        _useDaoAsExecutor(destination);
        destination.dao
            .revoke(address(destination.dao), address(destination.controller), Permissions.EXECUTE_PERMISSION_ID);

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes memory encodedTx = _queuedPayload(origin, 0);

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the bridge delivery still succeeds");
        _assertDelivered(destination, txId);

        destination.dao
            .grant(address(destination.dao), address(destination.controller), Permissions.EXECUTE_PERMISSION_ID);

        _on(destination);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice An action that re-enters the execution target is blocked by its
    ///         reentrancy guard, and the message is stored as failed.
    function test_failure_actionReenteringTheExecutorIsBlocked() public {
        CallerReenterer reenterer = new CallerReenterer();

        bytes32 txId = _forwardViaProposal(
            origin,
            destination,
            GAS_LIMIT,
            _actionPayload(address(reenterer), 0, abi.encodeCall(CallerReenterer.callBackCaller, ()))
        );

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertDelivered(destination, txId);
    }
}
