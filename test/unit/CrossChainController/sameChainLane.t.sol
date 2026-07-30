// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";

import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Executor } from "@src/Executor.sol";

import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { SameChainAdapter } from "@mocks/SameChainAdapter.sol";
import { CounterTarget } from "@mocks/CounterTarget.sol";

/// @title SameChainLaneTest
/// @notice Covers the chain-x-to-chain-x lane `updateConfig` permits, in the
///         shape it exists to serve: the executor is the DAO and the send is
///         initiated from inside a DAO `execute` frame.
///
/// @dev WHY THE ADAPTER RUNS THE PAYLOAD ITSELF. Routing a same-chain delivery
///      back through `receiveMessage` re-enters the still-open outer `execute`
///      frame. A `nonReentrant` executor rejects the inner call,
///      `receiveMessage`'s `try/catch` absorbs the revert, and the message
///      strands as `Delivered` with nothing surfaced to the caller.
///      `SameChainAdapter` calls the executor directly to stay out of that
///      nesting — see the mock for what that trades away.
///
///      Consequently there is no `_transactions` record to assert on here: the
///      controller's receive path is not involved. What these tests pin is the
///      send half plus the executor call — that `forwardMessage` reaches the
///      executor, that the payload runs, and that the execution-context guards
///      still hold.
contract SameChainLaneTest is CrossChainControllerBase {
    SameChainAdapter internal loopback;
    Executor internal executor;
    CounterTarget internal counter;

    uint256 internal constant LOOPBACK_MESSAGE_ID = 7777;

    function setUp() public override {
        super.setUp();

        counter = new CounterTarget();
        executor = new Executor();

        loopback = new SameChainAdapter(address(controller), address(executor), LOOPBACK_MESSAGE_ID);

        // The adapter's send frame runs AS the controller, so `onlyOwner` on the
        // executor sees the controller.
        executor.transferOwnership(address(controller));

        // Both halves of the lane are the same contract on the same chain.
        _configureLane(block.chainid, address(loopback), address(loopback));
    }

    // -------------------------------------------------------------------------
    // The round trip.
    // -------------------------------------------------------------------------

    /// @dev The shape the lane exists for: the DAO executes an action calling
    ///      `forwardMessage`, and the payload runs before that outer `execute`
    ///      returns — no re-entrancy, because the payload never re-enters the
    ///      DAO.
    function test_forwardMessageFromDaoExecutesPayload() public {
        Action[] memory governanceActions = new Action[](1);
        governanceActions[0] = Action({
            to: address(controller),
            value: 0,
            data: abi.encodeCall(controller.forwardMessage, (block.chainid, GAS_LIMIT, _incrementPayload()))
        });

        daoMock.setHasPermission(address(controller), address(daoMock), forwardMessagePermissionId, true);

        // forge-lint: disable-next-line(unsafe-typecast)
        daoMock.execute(bytes32("gov"), governanceActions, 0);

        assertEq(counter.count(), 1, "payload did not execute");
    }

    /// @dev The same send from an ordinary permission holder, for contrast: one
    ///      call, payload executed by the time it returns.
    function test_forwardMessageExecutesPayloadInOneCall() public {
        vm.prank(alice);
        controller.forwardMessage(block.chainid, GAS_LIMIT, _incrementPayload());

        assertEq(counter.count(), 1, "payload did not execute");
    }

    /// @dev The txId `forwardMessage` returns is the canonical envelope hash,
    ///      and is what the adapter hands the executor as its `callId`.
    function test_returnedTxIdIsCanonicalEnvelopeHash() public {
        bytes memory message = _incrementPayload();

        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(block.chainid, GAS_LIMIT, message);

        Transaction memory expected = Transaction({
            nonce: 1,
            origin: alice,
            controller: address(controller),
            originChainId: block.chainid,
            destinationChainId: block.chainid,
            message: message
        });

        assertEq(txId, TransactionLib.id(expected), "txId is not the canonical envelope hash");
    }

    /// @dev The nonce keeps two identical payloads distinct, so a second send
    ///      produces a different txId and runs the payload again.
    function test_secondSendGetsFreshTxId() public {
        vm.startPrank(alice);
        bytes32 first = controller.forwardMessage(block.chainid, GAS_LIMIT, _incrementPayload());
        bytes32 second = controller.forwardMessage(block.chainid, GAS_LIMIT, _incrementPayload());
        vm.stopPrank();

        assertTrue(first != second, "nonce did not differentiate the envelopes");
        assertEq(counter.count(), 2, "payload did not execute twice");
    }

    /// @dev A failing action is NOT captured here — the receive path is not
    ///      involved, so the executor's revert bubbles all the way out and
    ///      reverts the send. This is the main behavioural difference from a
    ///      real lane, and pinning it keeps the trade-off visible.
    function test_failingActionRevertsTheSend() public {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeWithSignature("nonexistent()") });

        vm.expectRevert();
        vm.prank(alice);
        controller.forwardMessage(block.chainid, GAS_LIMIT, abi.encode(actions));

        assertEq(counter.count(), 0, "action should not have executed");
    }

    // -------------------------------------------------------------------------
    // Execution-context guards.
    // -------------------------------------------------------------------------

    /// @dev The send path is delegatecall-only. Reached directly,
    ///      `address(this)` is the adapter rather than the controller — which
    ///      also means `onlyOwner` on the executor would reject it.
    function test_directSendMessageReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.SEND_PATH_NOT_DELEGATECALLED.selector, address(loopback)));
        loopback.sendMessage(address(loopback), block.chainid, GAS_LIMIT, _emptyActionsPayload());
    }

    /// @dev The executor is owned by the controller, not the adapter: only a
    ///      delegatecalled send frame satisfies `onlyOwner`.
    function test_executorIsOwnedByController() public view {
        assertEq(executor.owner(), address(controller), "executor owner");
        assertEq(loopback.executor(), address(executor), "adapter executor");
    }

    // -------------------------------------------------------------------------
    // Chain id mapping.
    // -------------------------------------------------------------------------

    /// @dev The lane serves exactly one chain, so every other id is unmapped and
    ///      must revert rather than return a value (`IBaseAdapter`).
    function test_otherChainIdIsUnmapped() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_ID));
        loopback.toNativeChainId(CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, CHAIN_ID));
        loopback.fromNativeChainId(CHAIN_ID);
    }

    /// @dev This chain's own id maps through both directions unchanged.
    function test_thisChainIdRoundTrips() public view {
        assertEq(loopback.toNativeChainId(block.chainid), block.chainid, "toNativeChainId");
        assertEq(loopback.fromNativeChainId(block.chainid), block.chainid, "fromNativeChainId");
    }

    /// @dev A lane configured for a DIFFERENT chain id cannot be sent on: the
    ///      controller's config accepts it, but the adapter rejects the id it is
    ///      handed and the revert bubbles through `_dispatch`.
    function test_forwardOnForeignChainIdRevertsInAdapter() public {
        _configureLane(CHAIN_ID, address(loopback), address(loopback));

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_ID));
        vm.prank(alice);
        controller.forwardMessage(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
    }

    // -------------------------------------------------------------------------
    // Helpers.
    // -------------------------------------------------------------------------

    /// @dev A one-action payload incrementing `counter`, so execution is
    ///      observable rather than inferred from the absence of a revert.
    function _incrementPayload() internal view returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });
        return abi.encode(actions);
    }
}
