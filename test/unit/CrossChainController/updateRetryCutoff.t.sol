// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";
import { TransactionState } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { FlakyTarget } from "@mocks/FlakyTarget.sol";

contract CrossChainControllerUpdateRetryCutoffTest is CrossChainControllerBase {
    /// @dev Foundry's genesis timestamp is 1, which leaves no room below
    ///      `block.timestamp` for a valid cutoff; every test warps here first.
    /// @dev Declared as `uint120` -- the width `updateRetryCutoff` and
    ///      `TransactionRecord.bridgedAt` both use -- so cutoff arithmetic needs
    ///      no truncating casts.
    uint120 internal constant T0 = 1_000_000;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);
    }

    // -------------------------------------------------------------------------
    // Auth + input validation.
    // -------------------------------------------------------------------------

    function test_revertsIfCallerUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), bob, manageConfigPermissionId
            )
        );
        vm.prank(bob);
        controller.updateRetryCutoff(CHAIN_ID, T0);
    }

    function test_revertsIfOriginChainIdIsZero() public {
        vm.expectRevert(Errors.INVALID_CHAIN_ID.selector);
        vm.prank(alice);
        controller.updateRetryCutoff(0, T0);
    }

    /// @dev `0` can never clear a cutoff: the new value must be STRICTLY above
    ///      the current one, and the current one starts at `0`.
    function test_revertsIfCutoffIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.RETRY_CUTOFF_INVALID.selector, CHAIN_ID, uint120(0), uint120(0)));
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, 0);
    }

    /// @dev A future cutoff would pre-block messages that have not even been
    ///      delivered yet, so anything above `block.timestamp` is rejected.
    function test_revertsIfCutoffIsInTheFuture() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.RETRY_CUTOFF_INVALID.selector, CHAIN_ID, uint120(0), (T0 + 1)));
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, (T0 + 1));
    }

    /// @dev The cutoff is monotonic: once raised it can never be lowered or
    ///      re-set to the same value, so a later config holder cannot unblock a
    ///      backlog an earlier one blocked.
    function test_revertsIfCutoffNotAboveCurrent() public {
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0);

        vm.warp(T0 + 100);

        vm.expectRevert(abi.encodeWithSelector(Errors.RETRY_CUTOFF_INVALID.selector, CHAIN_ID, T0, T0));
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0);

        vm.expectRevert(abi.encodeWithSelector(Errors.RETRY_CUTOFF_INVALID.selector, CHAIN_ID, T0, (T0 - 1)));
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, (T0 - 1));
    }

    // -------------------------------------------------------------------------
    // Happy path.
    // -------------------------------------------------------------------------

    function test_setsCutoffAndEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(controller));
        emit RetryCutoffUpdated(CHAIN_ID, 0, T0);

        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0);

        assertEq(controller.retryCutoff(CHAIN_ID), T0);
    }

    function test_raisingCutoffEmitsTheReplacedValue() public {
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0);

        vm.warp(T0 + 100);

        vm.expectEmit(true, true, true, true, address(controller));
        emit RetryCutoffUpdated(CHAIN_ID, T0, (T0 + 100));

        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, (T0 + 100));

        assertEq(controller.retryCutoff(CHAIN_ID), (T0 + 100));
    }

    function test_cutoffIsPerOriginChain() public {
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0);

        assertEq(controller.retryCutoff(CHAIN_ID), T0);
        assertEq(controller.retryCutoff(OTHER_CHAIN_ID), 0, "another chain's cutoff must be untouched");
    }

    // -------------------------------------------------------------------------
    // Effect on `retryMessage` -- the reason the cutoff exists.
    // -------------------------------------------------------------------------

    /// @dev The boundary is INCLUSIVE: a message delivered exactly AT the
    ///      cutoff is blocked. The flaky target is fixed before the retry so
    ///      only the cutoff can be what blocks it.
    function test_blocksRetryOfMessageDeliveredAtOrBeforeCutoff() public {
        (FlakyTarget flaky, bytes memory encodedTx, bytes32 txId) = _deliverFailingMessage(1);

        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0); // == bridgedAt

        flaky.setShouldRevert(false);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_PREDATES_RETRY_CUTOFF.selector, txId, T0, T0));
        vm.prank(alice);
        controller.retryMessage(encodedTx);

        assertEq(
            uint256(controller.getTransaction(txId).state),
            uint256(TransactionState.Delivered),
            "a blocked message must stay Delivered (still cancellable)"
        );
    }

    function test_allowsRetryOfMessageDeliveredAfterCutoff() public {
        vm.prank(alice);
        controller.updateRetryCutoff(CHAIN_ID, T0);

        vm.warp(T0 + 1); // bridgedAt will be strictly above the cutoff
        (FlakyTarget flaky, bytes memory encodedTx, bytes32 txId) = _deliverFailingMessage(1);

        flaky.setShouldRevert(false);

        vm.expectEmit(true, true, true, true, address(controller));
        emit MessageRetried(txId);

        vm.prank(alice);
        controller.retryMessage(encodedTx);

        assertTrue(flaky.wasCalled(), "the retried action must actually have executed");
        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed));
    }

    // -------------------------------------------------------------------------
    // Helpers.
    // -------------------------------------------------------------------------

    /// @dev Delivers a message from `CHAIN_ID` whose single action reverts, so
    ///      it is stored as `Delivered` (failed, retryable) with
    ///      `bridgedAt = block.timestamp`.
    function _deliverFailingMessage(uint256 _nonce)
        internal
        returns (FlakyTarget flaky, bytes memory encodedTx, bytes32 txId)
    {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        flaky = new FlakyTarget();
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(flaky), value: 0, data: abi.encodeCall(FlakyTarget.maybeRevert, ()) });
        bytes memory message = abi.encode(actions);

        encodedTx = _encodedTx(_nonce, CHAIN_ID, message);
        txId = _txId(_nonce, CHAIN_ID, message);

        vm.prank(address(adapterA));
        controller.receiveMessage(_nonce, encodedTx, CHAIN_ID);
    }
}
