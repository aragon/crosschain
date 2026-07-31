// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";

import { CrossChainE2EBase } from "./Base.sol";
import { CCIPRelayRouterMock } from "@mocks/ccip/CCIPRelayRouterMock.sol";
import { GuardedTarget, ValueSink } from "@mocks/E2ETargets.sol";

/// @title CrossChainHappyPathE2ETest
/// @notice A message travelling the whole way: a passed proposal on the origin
///         DAO calls `forwardMessage`, the adapter hands it to CCIP, the peer
///         router delivers it, and the destination executor runs the actions.
contract CrossChainHappyPathE2ETest is CrossChainE2EBase {
    // -------------------------------------------------------------------------
    // The round trip.
    // -------------------------------------------------------------------------

    /// @notice The load-bearing test: an origin governance proposal produces an
    ///         action that runs on the destination chain.
    /// @dev `lastCaller` is the assertion that pins WHO executes. Inbound
    ///      payloads run on the `Executor`, not on the controller (which merely
    ///      drives it) and not on the adapter.
    function test_e2e_originProposalExecutesActionOnDestinationExecutor() public {
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));

        assertEq(destination.target.cancellations(), 0, "the action must not run at send time");

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "bridge-level delivery must succeed");
        _assertExecuted(destination, txId);

        assertEq(destination.target.cancellations(), 1, "the action must have run");
        assertEq(
            destination.target.lastCaller(),
            address(destination.executor),
            "the executor, not the controller or adapter, must be the caller"
        );
    }

    /// @notice The same lane carries messages the other way.
    function test_e2e_worksInBothDirections() public {
        bytes32 outbound = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        _deliverNext(origin, destination);
        _assertExecuted(destination, outbound);

        bytes32 inbound = _forwardViaProposal(destination, origin, GAS_LIMIT, _cancelPayload(origin));
        _deliverNext(destination, origin);

        _assertExecuted(origin, inbound);
        assertEq(origin.target.cancellations(), 1, "the reverse action must run");
        assertEq(origin.target.lastCaller(), address(origin.executor));
    }

    /// @notice A payload carrying several actions, including one that moves
    ///         native currency out of the destination executor's balance.
    /// @dev Value-bearing actions are paid by the EXECUTOR, which is why the
    ///      setup pre-funds it rather than the DAO.
    function test_e2e_multiActionPayloadIncludingValueTransfer() public {
        ValueSink sink = new ValueSink();
        vm.deal(address(destination.executor), 5 ether);

        Action[] memory actions = new Action[](3);
        actions[0] = Action({
            to: address(destination.target), value: 0, data: abi.encodeCall(GuardedTarget.cancelRootUpdate, ())
        });
        actions[1] = Action({ to: address(sink), value: 2 ether, data: "" });
        actions[2] = Action({
            to: address(destination.target), value: 0, data: abi.encodeCall(GuardedTarget.cancelRootUpdate, ())
        });

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, abi.encode(actions));
        _deliverNext(origin, destination);

        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 2, "both calls must run");
        assertEq(sink.received(), 2 ether, "value must have moved");
        assertEq(address(destination.executor).balance, 3 ether, "the remainder stays with the executor");
    }

    /// @notice An empty action array is a valid, executable message.
    function test_e2e_emptyPayloadExecutes() public {
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _emptyPayload());

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertExecuted(destination, txId);
    }

    /// @notice Consecutive sends take consecutive nonces, which is what makes
    ///         two otherwise identical messages distinct transactions.
    function test_e2e_consecutiveSendsTakeConsecutiveNonces() public {
        bytes memory payload = _cancelPayload(destination);

        bytes32 first = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);
        bytes32 second = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);

        assertTrue(first != second, "identical payloads must not collide");

        // The nonce starts at 1: `forwardMessage` pre-increments.
        assertEq(
            first,
            TransactionLib.id(_encodedTx(origin, destination, 1, address(origin.dao), payload)),
            "the first message must carry nonce 1"
        );
        assertEq(
            second,
            TransactionLib.id(_encodedTx(origin, destination, 2, address(origin.dao), payload)),
            "the second message must carry nonce 2"
        );

        _deliverNext(origin, destination);
        _deliverNext(origin, destination);

        _assertExecuted(destination, first);
        _assertExecuted(destination, second);
        assertEq(destination.target.cancellations(), 2);
    }

    /// @notice CCIP is configured with `allowOutOfOrderExecution`, so a later
    ///         message may be delivered before an earlier one.
    function test_e2e_outOfOrderDeliveryIsAccepted() public {
        bytes memory payload = _cancelPayload(destination);

        bytes32 first = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);
        bytes32 second = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);

        // Deliver the SECOND message first.
        assertTrue(_deliver(origin, destination, origin.router.messageIdAt(1)));
        _assertExecuted(destination, second);
        _assertUnknown(destination, first);

        assertTrue(_deliver(origin, destination, origin.router.messageIdAt(0)));
        _assertExecuted(destination, first);
    }

    /// @notice One controller serving two destinations. The nonce counter is
    ///         GLOBAL, not per-lane, so the two messages differ by nonce even
    ///         though they travel different lanes.
    function test_e2e_twoLanesFromOneControllerAreIndependent() public {
        Stack memory third = _deployThirdStack();

        bytes32 toB = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));
        bytes32 toC = _forwardViaProposal(origin, third, GAS_LIMIT, _cancelPayload(third));

        assertEq(
            toB,
            TransactionLib.id(_encodedTx(origin, destination, 1, address(origin.dao), _cancelPayload(destination))),
            "the Base-bound message must carry nonce 1"
        );
        assertEq(
            toC,
            TransactionLib.id(_encodedTx(origin, third, 2, address(origin.dao), _cancelPayload(third))),
            "the Arbitrum-bound message must carry nonce 2, not 1"
        );

        _deliverNext(origin, destination);
        _deliverNext(origin, third);

        _assertExecuted(destination, toB);
        _assertExecuted(third, toC);
        assertEq(destination.target.cancellations(), 1);
        assertEq(third.target.cancellations(), 1);
    }

    // -------------------------------------------------------------------------
    // Fee accounting on the happy path.
    // -------------------------------------------------------------------------

    /// @notice The native fee comes out of the CONTROLLER's balance -- the
    ///         consequence of the send path being `delegatecall`ed.
    function test_e2e_nativeFeeIsPaidFromTheControllerBalance() public {
        uint256 controllerBefore = address(origin.controller).balance;
        uint256 routerBefore = address(origin.router).balance;
        uint256 daoBefore = address(origin.dao).balance;

        _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));

        assertEq(address(origin.controller).balance, controllerBefore - FEE, "the controller must have paid the fee");
        assertEq(address(origin.router).balance, routerBefore + FEE, "the router must have received the fee");
        assertEq(address(origin.dao).balance, daoBefore, "the DAO's treasury must not be touched");
        assertEq(address(origin.adapter).balance, 0, "the adapter must never hold funds");
    }

    /// @notice `quoteFee` quotes the fee the send actually charges, and reports
    ///         the controller's own balance as what is available to pay it.
    function test_e2e_quoteMatchesTheFeeCharged() public {
        bytes memory payload = _cancelPayload(destination);

        vm.prank(address(origin.dao));
        (address token, uint256 quoted, uint256 available) =
            origin.controller.quoteFee(DESTINATION_CHAIN_ID, GAS_LIMIT, payload);

        assertEq(token, address(0), "this lane is native-fee");
        assertEq(quoted, FEE);
        assertEq(available, address(origin.controller).balance);

        uint256 before = address(origin.controller).balance;

        _forwardViaProposal(origin, destination, GAS_LIMIT, payload);

        assertEq(before - address(origin.controller).balance, quoted, "the send must charge exactly the quote");
    }

    // -------------------------------------------------------------------------
    // What the bridge actually carried.
    // -------------------------------------------------------------------------

    /// @notice The destination adapter must advertise `IAny2EVMMessageReceiver`.
    /// @dev A false here would make the production Router SKIP delivery and
    ///      report success, losing every inbound message silently.
    function test_e2e_adapterAdvertisesTheCcipReceiverInterface() public view {
        assertTrue(destination.adapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    }

    /// @notice The envelope the origin produced is exactly what the destination
    ///         authenticates: same bytes, same decoded fields, same txId.
    function test_e2e_bridgePayloadIsTheCanonicalEnvelope() public {
        bytes memory payload = _cancelPayload(destination);

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);

        Transaction memory sent = TransactionLib.decode(_queuedPayload(origin, 0));

        assertEq(sent.nonce, 1, "the first send must carry nonce 1");
        assertEq(sent.origin, address(origin.dao), "origin must be the caller of forwardMessage");
        assertEq(sent.controller, address(origin.controller));
        assertEq(sent.originChainId, ORIGIN_CHAIN_ID);
        assertEq(sent.destinationChainId, DESTINATION_CHAIN_ID);
        assertEq(sent.message, payload, "the inner payload must cross unmodified");

        assertEq(TransactionLib.id(sent), txId, "the txId the origin returned must hash what it actually sent");
    }

    /// @notice The account CCIP attributes the message to is the origin
    ///         CONTROLLER (because the send is a `delegatecall`), which is
    ///         exactly what the destination adapter's trusted remote holds.
    function test_e2e_bridgeSeesTheControllerAsSender() public {
        _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));

        CCIPRelayRouterMock.SentMessage memory sent = origin.router.sentAt(0);

        assertEq(sent.sender, address(origin.controller), "CCIP must attribute the send to the controller");
        assertTrue(sent.sender != address(origin.adapter), "the adapter must never be the attributed sender");
        assertEq(
            destination.adapter.trustedRemote(ORIGIN_CHAIN_ID),
            sent.sender,
            "the destination's trusted remote must be the attributed sender"
        );
        assertEq(sent.receiver, address(destination.adapter), "the bridge-level receiver must be the remote adapter");
        assertEq(sent.gasLimit, GAS_LIMIT, "the requested gas limit must survive into extraArgs");
        assertEq(sent.destinationChainSelector, DESTINATION_SELECTOR, "the lane must resolve to the right selector");
    }
}
