// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";

import { Transaction, TransactionLib, TransactionState } from "@src/lib/Transaction.sol";
import { Errors } from "@src/lib/Errors.sol";

import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { SameChainAdapter } from "@mocks/SameChainAdapter.sol";
import { CounterTarget } from "@mocks/CounterTarget.sol";

contract SameChainLaneTest is CrossChainControllerBase {
    SameChainAdapter internal loopback;
    CounterTarget internal counter;

    uint256 internal constant LOOPBACK_MESSAGE_ID = 7777;

    function setUp() public override {
        super.setUp();

        loopback = new SameChainAdapter(address(controller), LOOPBACK_MESSAGE_ID);
        counter = new CounterTarget();

        // Both halves of the lane are the same contract on the same chain.
        _configureLane(block.chainid, address(loopback), address(loopback));
    }

    // -------------------------------------------------------------------------
    // The round trip.
    // -------------------------------------------------------------------------

    /// @dev One `forwardMessage` ends with the actions already executed: the
    ///      loopback delivers synchronously, so by the time the call returns the
    ///      record is `Executed` and the target has been called.
    function test_forwardMessageDeliversAndExecutesInOneCall() public {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });

        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(block.chainid, GAS_LIMIT, abi.encode(actions));

        assertEq(counter.count(), 1, "action did not execute");
        assertEq(
            uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed), "record not Executed"
        );
        assertEq(controller.getTransaction(txId).bridgedAt, uint120(block.timestamp), "bridgedAt not stamped");
    }

    function test_returnedTxIdIsCanonicalEnvelopeHash() public {
        bytes memory message = _emptyActionsPayload();

        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(block.chainid, GAS_LIMIT, message);

        // Rebuilt independently: `origin` is the caller, `controller` is the
        // controller itself, and both chain ids are this chain.
        Transaction memory expected = Transaction({
            nonce: 1,
            origin: alice,
            controller: address(controller),
            originChainId: block.chainid,
            destinationChainId: block.chainid,
            message: message
        });

        assertEq(txId, TransactionLib.id(expected), "txId is not the canonical envelope hash");
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed), "not Executed");
    }

    function test_secondSendGetsFreshTxIdAndDoesNotReplay() public {
        bytes memory message = _emptyActionsPayload();

        vm.startPrank(alice);
        bytes32 first = controller.forwardMessage(block.chainid, GAS_LIMIT, message);
        bytes32 second = controller.forwardMessage(block.chainid, GAS_LIMIT, message);
        vm.stopPrank();

        assertTrue(first != second, "nonce did not differentiate the envelopes");
        assertEq(uint256(controller.getTransaction(first).state), uint256(TransactionState.Executed), "first state");
        assertEq(uint256(controller.getTransaction(second).state), uint256(TransactionState.Executed), "second state");
    }

    function test_failingActionIsCapturedAsDelivered() public {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeWithSignature("nonexistent()") });

        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(block.chainid, GAS_LIMIT, abi.encode(actions));

        assertEq(counter.count(), 0, "action should not have executed");
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered), "not Delivered");
    }

    function test_capturedMessageCanBeRetried() public {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });
        bytes memory message = abi.encode(actions);

        // Break the action, deliver, then repair it so the retry can succeed.
        vm.etch(address(counter), hex"fe");

        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(block.chainid, GAS_LIMIT, message);
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Delivered), "not Delivered");

        vm.etch(address(counter), address(new CounterTarget()).code);

        bytes memory encodedTx = TransactionLib.encode(
            Transaction({
                nonce: 1,
                origin: alice,
                controller: address(controller),
                originChainId: block.chainid,
                destinationChainId: block.chainid,
                message: message
            })
        );

        vm.prank(alice);
        controller.retryMessage(encodedTx);

        assertEq(counter.count(), 1, "retry did not execute the action");
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed), "not Executed");
    }

    // -------------------------------------------------------------------------
    // Execution-context guards.
    // -------------------------------------------------------------------------

    function test_directSendMessageReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.SEND_PATH_NOT_DELEGATECALLED.selector, address(loopback)));
        loopback.sendMessage(address(loopback), block.chainid, GAS_LIMIT, _emptyActionsPayload());
    }

    function test_directDeliverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, address(this)));
        loopback.deliver(LOOPBACK_MESSAGE_ID, _encodedEmptyTx(1, block.chainid), block.chainid);
    }

    function test_otherChainIdIsUnmapped() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_ID));
        loopback.toNativeChainId(CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, CHAIN_ID));
        loopback.fromNativeChainId(CHAIN_ID);
    }

    function test_thisChainIdRoundTrips() public view {
        assertEq(loopback.toNativeChainId(block.chainid), block.chainid, "toNativeChainId");
        assertEq(loopback.fromNativeChainId(block.chainid), block.chainid, "fromNativeChainId");
    }

    function test_forwardOnForeignChainIdRevertsInAdapter() public {
        _configureLane(CHAIN_ID, address(loopback), address(loopback));

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_ID));
        vm.prank(alice);
        controller.forwardMessage(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
    }
}
