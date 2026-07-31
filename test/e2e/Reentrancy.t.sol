// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Executor as CommonsExecutor } from "@aragon/osx-commons-contracts/src/executors/Executor.sol";

import { ICrossChainController } from "@src/ICrossChainController.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { TransactionLib } from "@src/lib/Transaction.sol";

import { CrossChainE2EBase } from "./Base.sol";
import { CallProbe } from "@mocks/E2ETargets.sol";

/// @title CrossChainReentrancyE2ETest
/// @notice What an authenticated inbound payload can and cannot do to the
///         cross-chain machinery while it is running.
///
/// @dev A message cannot re-enter ITSELF: to name its own transaction, its own
///      envelope would have to contain its own hash. There is no arrangement of
///      bytes that does. What IS reachable is a payload acting on some OTHER
///      transaction, and that is what these tests cover.
///
///      The tests use `CallProbe`, which swallows the inner call's revert and
///      records it, so the outer message still completes and the exact reason
///      the inner call was refused can be asserted. A bare re-entrant action
///      would just abort the whole payload and prove less.
contract CrossChainReentrancyE2ETest is CrossChainE2EBase {
    /// @dev A payload that itself performs a full `ccipSend`, or a whole nested
    ///      `execute`, costs far more than the suite's default destination gas
    ///      limit. Under-gassing it would land these messages in the regimes
    ///      `GasLimits.t.sol` covers rather than the behaviour under test here.
    uint256 internal constant NESTED_GAS_LIMIT = 2_000_000;

    CallProbe internal probe;

    function setUp() public virtual override {
        super.setUp();

        probe = new CallProbe();
        vm.label(address(probe), "probe");
    }

    /// @dev Parks a genuinely failed transaction on the destination, ready to be
    ///      the subject of a re-entrant retry.
    function _parkFailedTransaction() internal returns (bytes32 txId, bytes memory encodedTx) {
        destination.target.setLocked(true);

        txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        encodedTx = _queuedPayload(origin, 0);

        _deliverNext(origin, destination);
        _assertDelivered(destination, txId);

        destination.target.setLocked(false);
    }

    /// @dev A payload whose single action drives the probe at `_target`.
    function _probePayload(address _target, bytes memory _data) internal view returns (bytes memory) {
        return _actionPayload(address(probe), 0, abi.encodeCall(CallProbe.probe, (_target, _data)));
    }

    /// @dev A payload whose single action makes the destination controller send
    ///      a message of its own.
    function _chainedHopPayload(bytes memory _secondHop) internal view returns (bytes memory) {
        return _actionPayload(
            address(destination.controller),
            0,
            abi.encodeCall(ICrossChainController.forwardMessage, (origin.chainId, GAS_LIMIT, _secondHop))
        );
    }

    // -------------------------------------------------------------------------
    // Re-entering the controller mid-execution.
    // -------------------------------------------------------------------------

    /// @notice A payload cannot feed the controller a new inbound message: it is
    ///         not a registered adapter, whatever else it may be.
    function test_reentrancy_payloadCannotCallReceiveMessage() public {
        bytes memory inner = abi.encodeCall(
            ICrossChainController.receiveMessage,
            (
                uint256(keccak256("injected")),
                _encodedTx(origin, destination, 99, address(origin.dao), _cancelPayload(destination)),
                origin.chainId
            )
        );

        bytes32 txId = _forwardViaProposal(
            origin, destination, NESTED_GAS_LIMIT, _probePayload(address(destination.controller), inner)
        );

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertExecuted(destination, txId);

        assertFalse(probe.lastSuccess(), "the injection must have failed");
        assertEq(
            probe.lastReturnData(), abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, address(probe))
        );
    }

    /// @notice A payload cannot retry another stored transaction unless it holds
    ///         the permission.
    /// @dev The blast radius of an attacker-authored payload: a cross-chain
    ///      message runs as the EXECUTOR for its own actions, but any action it
    ///      routes through an intermediate contract runs as THAT contract, and
    ///      the permission check follows the actual caller.
    function test_reentrancy_payloadCannotRetryAnotherTransactionUnpermissioned() public {
        (bytes32 parkedId, bytes memory parked) = _parkFailedTransaction();

        _forwardViaProposal(
            origin,
            destination,
            NESTED_GAS_LIMIT,
            _probePayload(address(destination.controller), abi.encodeCall(ICrossChainController.retryMessage, (parked)))
        );
        _deliverNext(origin, destination);

        assertFalse(probe.lastSuccess(), "the probe holds no retry permission");
        _assertDelivered(destination, parkedId);
        assertEq(destination.target.cancellations(), 0);
    }

    /// @notice A delivered payload cannot drive a retry EVEN WITH the permission
    ///         -- the executor's reentrancy guard forbids it.
    /// @dev `retryMessage` re-enters `Executor.execute`, and a delivered payload
    ///      is already inside one. So "send a cross-chain proposal that clears a
    ///      stuck message on the destination" does not work, however the
    ///      permissions are arranged. This is the same mechanic
    ///      `Permissions.RETRY_MESSAGE_PERMISSION_ID` warns about, reached from
    ///      the cross-chain side instead of the local one.
    function test_reentrancy_payloadCannotRetryEvenWithThePermission() public {
        (bytes32 parkedId, bytes memory parked) = _parkFailedTransaction();

        destination.dao.grant(address(destination.controller), address(probe), Permissions.RETRY_MESSAGE_PERMISSION_ID);

        _forwardViaProposal(
            origin,
            destination,
            NESTED_GAS_LIMIT,
            _probePayload(address(destination.controller), abi.encodeCall(ICrossChainController.retryMessage, (parked)))
        );
        _deliverNext(origin, destination);

        assertFalse(probe.lastSuccess(), "the nested execute must be refused");
        assertEq(
            probe.lastReturnData(),
            abi.encodeWithSelector(CommonsExecutor.ReentrantCall.selector),
            "the executor's reentrancy guard is what stops it"
        );
        _assertDelivered(destination, parkedId);
        assertEq(destination.target.cancellations(), 0);
    }

    /// @notice Retrying a transaction that is mid-execution is refused: its state
    ///         is still `None` until the execution returns.
    /// @dev Proved on a transaction the payload CAN name -- a second message
    ///      delivered while the first is still running is impossible to arrange,
    ///      so this instead names a transaction that has never been delivered at
    ///      all, which is the same state (`None`) the executing one is in. What
    ///      it pins is that `retryMessage`'s gate is the `Delivered` state
    ///      specifically, not merely "not Executed".
    function test_reentrancy_retryOfANeverDeliveredTransactionIsRefused() public {
        bytes memory neverSent = _encodedTx(origin, destination, 42, address(origin.dao), _cancelPayload(destination));

        destination.dao.grant(address(destination.controller), address(probe), Permissions.RETRY_MESSAGE_PERMISSION_ID);

        _forwardViaProposal(
            origin,
            destination,
            NESTED_GAS_LIMIT,
            _probePayload(
                address(destination.controller), abi.encodeCall(ICrossChainController.retryMessage, (neverSent))
            )
        );
        _deliverNext(origin, destination);

        assertFalse(probe.lastSuccess());
        assertEq(
            probe.lastReturnData(),
            abi.encodeWithSelector(
                Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, TransactionLib.id(neverSent)
            ),
            "a None transaction is not retryable"
        );
    }

    // -------------------------------------------------------------------------
    // Legitimate chaining.
    // -------------------------------------------------------------------------

    /// @notice The multi-hop path needs the destination EXECUTOR to hold
    ///         `FORWARD_MESSAGE_PERMISSION`, and fails closed without it.
    /// @dev Worth pinning because the permission is easy to get wrong. A
    ///      delivered payload's actions are issued by the executor, not by the
    ///      DAO, so granting the DAO alone -- which is what a single-chain
    ///      deployment needs -- leaves every second hop failing. It fails safely
    ///      (stored, retryable), but it fails.
    function test_reentrancy_chainedHopNeedsTheExecutorToHoldForwardPermission() public {
        bytes32 txId =
            _forwardViaProposal(origin, destination, NESTED_GAS_LIMIT, _chainedHopPayload(_cancelPayload(origin)));

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the delivery still succeeds");
        _assertDelivered(destination, txId);
        assertEq(destination.router.sentCount(), 0, "no second hop may have been sent");
    }

    /// @notice A delivered message MAY start a new cross-chain message: an origin
    ///         proposal that makes the destination send one back.
    /// @dev The multi-hop governance path (A tells B to tell A).
    function test_reentrancy_deliveredMessageCanForwardAnotherMessage() public {
        destination.dao
            .grant(
                address(destination.controller),
                address(destination.executor),
                Permissions.FORWARD_MESSAGE_PERMISSION_ID
            );

        bytes memory secondHop = _cancelPayload(origin);

        bytes32 outbound = _forwardViaProposal(origin, destination, NESTED_GAS_LIMIT, _chainedHopPayload(secondHop));

        _deliverNext(origin, destination);
        _assertExecuted(destination, outbound);

        // The destination controller produced a message of its own.
        assertEq(destination.router.sentCount(), 1, "the hop must have sent");

        // The second hop's `origin` field is the EXECUTOR: it is what called
        // `forwardMessage`, one frame below the controller.
        bytes32 inbound =
            TransactionLib.id(_encodedTx(destination, origin, 1, address(destination.executor), secondHop));

        _deliverNext(destination, origin);

        _assertExecuted(origin, inbound);
        assertEq(origin.target.cancellations(), 1, "the round trip must have closed");
        assertEq(origin.target.lastCaller(), address(origin.executor));
    }

    /// @notice The chained hop is paid by the DESTINATION controller, out of its
    ///         own pre-funding.
    function test_reentrancy_chainedHopIsPaidByTheDestinationController() public {
        destination.dao
            .grant(
                address(destination.controller),
                address(destination.executor),
                Permissions.FORWARD_MESSAGE_PERMISSION_ID
            );

        uint256 balanceBefore = address(destination.controller).balance;

        _forwardViaProposal(origin, destination, NESTED_GAS_LIMIT, _chainedHopPayload(_cancelPayload(origin)));
        _deliverNext(origin, destination);

        assertEq(
            address(destination.controller).balance,
            balanceBefore - FEE,
            "the destination controller pays for its own hop"
        );
    }

    /// @notice A chained hop whose controller is unfunded fails the payload,
    ///         which is then recoverable by funding and retrying.
    /// @dev The failure mode a multi-hop cross-chain proposal actually hits in
    ///      production: hop two is only as reliable as the SECOND chain's fee
    ///      balance, which the origin DAO does not control and cannot see.
    function test_reentrancy_unfundedChainedHopIsStoredAndRetryable() public {
        destination.dao
            .grant(
                address(destination.controller),
                address(destination.executor),
                Permissions.FORWARD_MESSAGE_PERMISSION_ID
            );

        vm.deal(address(destination.controller), 0);

        bytes32 txId =
            _forwardViaProposal(origin, destination, NESTED_GAS_LIMIT, _chainedHopPayload(_cancelPayload(origin)));
        bytes memory encodedTx = _queuedPayload(origin, 0);

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertDelivered(destination, txId);
        assertEq(destination.router.sentCount(), 0, "nothing may have been sent");

        vm.deal(address(destination.controller), 1 ether);

        _on(destination);
        vm.prank(ops);
        destination.controller.retryMessage(encodedTx);
        _on(origin);

        _assertExecuted(destination, txId);
        assertEq(destination.router.sentCount(), 1);
    }
}
