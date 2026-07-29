// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Transaction, TransactionState, TransactionLib } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { ActionExecute } from "@osx-test/mocks/commons/executors/ActionExecute.sol";

contract CrossChainControllerPauseTest is CrossChainControllerBase {
    /// @dev OZ `security/Pausable` reverts with this string.
    bytes internal constant PAUSED_REVERT = bytes("Pausable: paused");

    event Paused(address account);
    event Unpaused(address account);

    // -------------------------------------------------------------------------
    // pause / unpause mechanics + auth
    // -------------------------------------------------------------------------

    function test_startsUnpaused() public view {
        assertFalse(controller.paused());
    }

    function test_pauseSetsPausedAndEmits() public {
        vm.expectEmit(false, false, false, true, address(controller));
        emit Paused(alice);

        vm.prank(alice);
        controller.pause();

        assertTrue(controller.paused());
    }

    function test_unpauseClearsPausedAndEmits() public {
        vm.prank(alice);
        controller.pause();

        vm.expectEmit(false, false, false, true, address(controller));
        emit Unpaused(alice);

        vm.prank(alice);
        controller.unpause();

        assertFalse(controller.paused());
    }

    function test_pauseRevertsIfCallerUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), bob, pausePermissionId
            )
        );
        vm.prank(bob);
        controller.pause();
    }

    function test_unpauseRevertsIfCallerUnauthorized() public {
        vm.prank(alice);
        controller.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), bob, unpausePermissionId
            )
        );
        vm.prank(bob);
        controller.unpause();
    }

    /// @dev The permissions are deliberately split: holding `PAUSE_PERMISSION`
    ///      alone (the guardian setup) must not be enough to reopen the paths.
    function test_unpauseRevertsIfCallerOnlyHoldsPausePermission() public {
        address guardian = makeAddr("guardian");
        daoMock.setHasPermission(address(controller), guardian, pausePermissionId, true);

        vm.prank(guardian);
        controller.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), guardian, unpausePermissionId
            )
        );
        vm.prank(guardian);
        controller.unpause();
    }

    function test_pauseRevertsIfAlreadyPaused() public {
        vm.prank(alice);
        controller.pause();

        vm.expectRevert(PAUSED_REVERT);
        vm.prank(alice);
        controller.pause();
    }

    function test_unpauseRevertsIfNotPaused() public {
        vm.expectRevert(bytes("Pausable: not paused"));
        vm.prank(alice);
        controller.unpause();
    }

    // -------------------------------------------------------------------------
    // The three message paths are blocked while paused.
    // -------------------------------------------------------------------------

    function test_forwardMessageRevertsWhenPaused() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.prank(alice);
        controller.pause();

        vm.expectRevert(PAUSED_REVERT);
        vm.prank(alice);
        controller.forwardMessage(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
    }

    function test_receiveMessageRevertsWhenPaused() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.prank(alice);
        controller.pause();

        // `whenNotPaused` sits ahead of `onlyLocalAdapter`, so even the
        // registered local adapter is blocked.
        vm.expectRevert(PAUSED_REVERT);
        vm.prank(address(adapterA));
        controller.receiveMessage(1, _encodedEmptyTx(1, CHAIN_ID), CHAIN_ID);
    }

    function test_retryMessageRevertsWhenPaused() public {
        vm.prank(alice);
        controller.pause();

        vm.expectRevert(PAUSED_REVERT);
        vm.prank(alice);
        controller.retryMessage(_encodedEmptyTx(1, CHAIN_ID));
    }

    /// @dev Cancelling is deliberately exempt from `whenNotPaused`: bad messages
    ///      must stay neutralisable during an incident, which is exactly when
    ///      the controller is paused.
    function test_cancelMessageWorksWhenPaused() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        // Deliver a message whose execution fails, leaving it `Delivered`.
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(actionTarget), value: 0, data: abi.encodeCall(ActionExecute.fail, ()) });
        Transaction memory failedTx = _tx(1, CHAIN_ID, abi.encode(actions));
        bytes32 txId = TransactionLib.id(failedTx);

        vm.prank(address(adapterA));
        controller.receiveMessage(1, TransactionLib.encode(failedTx), CHAIN_ID);

        vm.prank(alice);
        controller.pause();

        vm.prank(alice);
        controller.cancelMessage(TransactionLib.encode(failedTx));

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Cancelled));
    }

    // -------------------------------------------------------------------------
    // The message paths work again after unpause.
    // -------------------------------------------------------------------------

    function test_receiveMessageWorksAgainAfterUnpause() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.prank(alice);
        controller.pause();
        vm.prank(alice);
        controller.unpause();

        // Does not revert with the paused error; delivers normally.
        vm.prank(address(adapterA));
        bytes32 txId = controller.receiveMessage(1, _encodedEmptyTx(1, CHAIN_ID), CHAIN_ID);
        assertEq(txId, _txId(1, CHAIN_ID, _emptyActionsPayload()));
    }

    // -------------------------------------------------------------------------
    // Admin paths remain callable while paused (recovery must stay possible).
    // -------------------------------------------------------------------------

    function test_updateConfigStillWorksWhilePaused() public {
        vm.prank(alice);
        controller.pause();

        // `updateConfig` is NOT gated by `whenNotPaused`; repointing a lane
        // during an incident must remain possible.
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        assertTrue(controller.isRegisteredLocalAdapter(address(adapterA), CHAIN_ID));
    }

    function test_sweepStillWorksWhilePaused() public {
        vm.deal(address(controller), 1 ether);
        address recipient = makeAddr("recipient");

        vm.prank(alice);
        controller.pause();

        vm.prank(alice);
        controller.sweep(address(0), recipient, 1 ether);

        assertEq(recipient.balance, 1 ether);
    }
}
