// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { ICrossChainController } from "@src/ICrossChainController.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Permissions } from "@src/lib/Permissions.sol";

import { CrossChainE2EBase } from "./Base.sol";

/// @title CrossChainAuthorizationE2ETest
/// @notice Every gate on the cross-chain path, exercised against a REAL OSx
///         `PermissionManager` rather than a settable mock.
///
/// @dev WHY THIS EXISTS ALONGSIDE THE UNIT SUITES. The per-function suites
///      assert that each entry point CALLS the right permission check, using
///      `CrossChainControllerDAOMock` whose `hasPermission` is a mapping the
///      test writes directly. None of them prove that a real `DAO.grant` makes
///      the check pass, that a real `DAO.revoke` makes it fail again, or that
///      the exact `DaoUnauthorized` payload a real manager produces is the one
///      callers will see.
///
///      NOT REPEATED HERE: `DELEGATE_CALL_FORBIDDEN`, which needs an execution
///      context the real wiring cannot produce. It is owned by
///      `test/unit/adapters/CCIPAdapter/ccipReceive.t.sol`, which uses
///      `DelegateCallerMock` to construct it.
contract CrossChainAuthorizationE2ETest is CrossChainE2EBase {
    // -------------------------------------------------------------------------
    // Outbound.
    // -------------------------------------------------------------------------

    /// @notice Only a holder of `FORWARD_MESSAGE_PERMISSION` may send.
    function test_auth_strangerCannotForward() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(origin.dao),
                address(origin.controller),
                stranger,
                Permissions.FORWARD_MESSAGE_PERMISSION_ID
            )
        );
        origin.controller.forwardMessage(destination.chainId, GAS_LIMIT, _emptyPayload());
    }

    /// @notice Revoking the permission through the real DAO stops the sends that
    ///         were working a moment earlier.
    function test_auth_revokingForwardPermissionStopsSending() public {
        _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));

        origin.dao.revoke(address(origin.controller), address(origin.dao), Permissions.FORWARD_MESSAGE_PERMISSION_ID);

        vm.prank(address(origin.dao));
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(origin.dao),
                address(origin.controller),
                address(origin.dao),
                Permissions.FORWARD_MESSAGE_PERMISSION_ID
            )
        );
        origin.controller.forwardMessage(destination.chainId, GAS_LIMIT, _emptyPayload());
    }

    /// @notice Sending to a chain with no lane is rejected, rather than silently
    ///         succeeding against a zero adapter.
    function test_auth_forwardToUnconfiguredChainReverts() public {
        vm.prank(address(origin.dao));
        vm.expectRevert(abi.encodeWithSelector(Errors.ADAPTER_NOT_CONFIGURED.selector, UNCONFIGURED_CHAIN_ID));
        origin.controller.forwardMessage(UNCONFIGURED_CHAIN_ID, GAS_LIMIT, _emptyPayload());
    }

    /// @notice The adapter's send path refuses to run outside a `delegatecall`
    ///         from its controller.
    /// @dev A direct call would pay the fee from the ADAPTER's (empty) balance
    ///      and make the bridge attribute the message to the adapter, which no
    ///      destination trusts.
    function test_auth_adapterSendPathRejectsDirectCalls() public {
        vm.prank(address(origin.dao));
        vm.expectRevert(abi.encodeWithSelector(Errors.SEND_PATH_NOT_DELEGATECALLED.selector, address(origin.adapter)));
        origin.adapter.sendMessage(address(destination.adapter), destination.chainId, GAS_LIMIT, _emptyPayload());
    }

    // -------------------------------------------------------------------------
    // Inbound: the controller's view.
    // -------------------------------------------------------------------------

    /// @notice Only a registered local adapter may hand the controller a message.
    function test_auth_strangerCannotCallReceiveMessage() public {
        _on(destination);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, stranger));
        destination.controller
            .receiveMessage(
                uint256(keccak256("forged")),
                _encodedTx(origin, destination, 1, address(origin.dao), _cancelPayload(destination)),
                origin.chainId
            );
    }

    /// @notice An adapter registered for ONE lane cannot inject messages
    ///         claiming to come from a different chain.
    /// @dev The lane registration is per origin chain id, so a compromised
    ///      adapter's blast radius is the single lane it serves.
    function test_auth_adapterCannotInjectForALaneItDoesNotServe() public {
        _on(destination);

        vm.prank(address(destination.adapter));
        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_LOCAL_ADAPTER.selector, address(destination.adapter)));
        destination.controller
            .receiveMessage(
                uint256(keccak256("forged")),
                _encodedTx(origin, destination, 1, address(origin.dao), _cancelPayload(destination)),
                THIRD_CHAIN_ID
            );
    }

    /// @notice The internal execution entry point is not callable from outside.
    function test_auth_executeActionsIsSelfOnly() public {
        _on(destination);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.CALLER_NOT_SELF.selector, stranger));
        destination.controller.executeActions(keccak256("txId"), _cancelPayload(destination));
    }

    /// @notice The executor only takes orders from its controller, so a stranger
    ///         cannot run actions on it directly.
    /// @dev This is the gate that makes the whole inbound path meaningful: if
    ///      anyone could drive the executor, authenticating the bridge message
    ///      would buy nothing.
    function test_auth_executorRejectsCallersOtherThanTheController() public {
        _on(destination);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        destination.executor.execute(keccak256("txId"), new Action[](0), 0);
    }

    // -------------------------------------------------------------------------
    // Inbound: the adapter's view.
    // -------------------------------------------------------------------------

    /// @notice Only the CCIP Router may deliver to the adapter.
    function test_auth_onlyTheRouterMayCallCcipReceive() public {
        _on(destination);

        vm.prank(stranger);
        vm.expectRevert(Errors.CALLER_NOT_CCIP_ROUTER.selector);
        destination.adapter
            .ccipReceive(
                _any2Evm(
                    keccak256("forged"),
                    ORIGIN_SELECTOR,
                    abi.encode(address(origin.controller)),
                    _cancelPayload(destination)
                )
            );
    }

    /// @notice A sender the adapter does not trust is rejected, even when the
    ///         Router itself delivers the message.
    function test_auth_untrustedSenderIsRejected() public {
        (bool success, bytes memory reason) = _forgeDelivery(
            destination,
            keccak256("forged"),
            ORIGIN_SELECTOR,
            makeAddr("someOtherContract"),
            _encodedTx(origin, destination, 1, address(origin.dao), _cancelPayload(destination)),
            GAS_LIMIT
        );

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(Errors.REMOTE_NOT_TRUSTED.selector));
    }

    /// @notice Trusting the remote ADAPTER instead of the remote CONTROLLER is
    ///         the canonical misconfiguration of this design, and it fails
    ///         closed.
    /// @dev Because the send path is `delegatecall`ed, the bridge attributes
    ///      every message to the origin CONTROLLER. An operator who wires the
    ///      trusted remote to the origin ADAPTER -- the address that looks like
    ///      "the bridge component on the other side" -- gets a lane where every
    ///      single message is rejected. This test is the executable version of
    ///      that warning.
    function test_auth_deliveryFromTheRemoteAdapterIsRejected() public {
        (bool success, bytes memory reason) = _forgeDelivery(
            destination,
            keccak256("from-the-remote-adapter"),
            ORIGIN_SELECTOR,
            address(origin.adapter),
            _encodedTx(origin, destination, 1, address(origin.dao), _cancelPayload(destination)),
            GAS_LIMIT
        );

        assertFalse(success, "the remote ADAPTER is not the trusted remote");
        assertEq(reason, abi.encodeWithSelector(Errors.REMOTE_NOT_TRUSTED.selector));
        assertEq(
            destination.adapter.trustedRemote(origin.chainId),
            address(origin.controller),
            "the trusted remote is the remote CONTROLLER"
        );
    }

    /// @notice A source chain the adapter cannot map to a standard chain id is
    ///         rejected before anything else is looked at.
    function test_auth_unknownSourceSelectorIsRejected() public {
        uint64 unknownSelector = 1234567890;

        (bool success, bytes memory reason) = _forgeDelivery(
            destination,
            keccak256("from-nowhere"),
            unknownSelector,
            address(origin.controller),
            _emptyPayload(),
            GAS_LIMIT
        );

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, uint256(unknownSelector)));
    }

    /// @notice A selector the adapter CAN map, but for which no trusted remote
    ///         was configured, is rejected too.
    /// @dev The seeding is the premise, not setup noise: a stack only seeds the
    ///      lanes it uses, so without this the delivery would fail one step
    ///      earlier with `UNKNOWN_NATIVE_CHAIN_ID` and prove nothing about the
    ///      trusted-remote check.
    function test_auth_mappedSelectorWithoutATrustedRemoteIsRejected() public {
        uint64 polygonSelector = ccipSelector("polygon");
        destination.registry.setChainIdPair(UNCONFIGURED_CHAIN_ID, polygonSelector);

        (bool success, bytes memory reason) = _forgeDelivery(
            destination,
            keccak256("from-polygon"),
            polygonSelector,
            address(origin.controller),
            _emptyPayload(),
            GAS_LIMIT
        );

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(Errors.REMOTE_NOT_TRUSTED.selector));
        assertEq(destination.adapter.trustedRemote(UNCONFIGURED_CHAIN_ID), address(0));
    }

    /// @notice Sender bytes that do not decode to an address are rejected.
    function test_auth_malformedSenderBytesAreRejected() public {
        (bool success,) = _forgeDeliveryRaw(
            destination, keccak256("malformed"), ORIGIN_SELECTOR, hex"c0ffee", _emptyPayload(), GAS_LIMIT
        );

        assertFalse(success, "undecodable sender bytes must be rejected");
    }

    /// @notice A sender that decodes to the zero address is rejected too.
    function test_auth_zeroSenderIsRejected() public {
        (bool success, bytes memory reason) = _forgeDelivery(
            destination, keccak256("zero-sender"), ORIGIN_SELECTOR, address(0), _emptyPayload(), GAS_LIMIT
        );

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(Errors.REMOTE_NOT_TRUSTED.selector));
    }

    // -------------------------------------------------------------------------
    // Configuration.
    // -------------------------------------------------------------------------

    /// @notice Reconfiguring lanes needs the permission.
    /// @dev `MANAGE_CONTROLLER_CONFIG_PERMISSION` is effectively root over the
    ///      cross-chain path: whoever holds it can point a lane at an adapter
    ///      they control and authorise themselves to execute.
    function test_auth_strangerCannotUpdateConfig() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = destination.chainId;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] = ICrossChainController.ChainConfig({ localAdapter: stranger, remoteAdapter: stranger });

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(origin.dao),
                address(origin.controller),
                stranger,
                Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID
            )
        );
        origin.controller.updateConfig(chainIds, configs);
    }

    /// @notice Sweeping needs the permission.
    function test_auth_strangerCannotSweep() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(origin.dao),
                address(origin.controller),
                stranger,
                Permissions.SWEEP_PERMISSION_ID
            )
        );
        origin.controller.sweep(address(0), stranger, 1 ether);
    }

    /// @notice A half-configured lane is rejected: a lane is either fully set or
    ///         fully cleared.
    function test_auth_partiallyConfiguredLaneIsRejected() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = UNCONFIGURED_CHAIN_ID;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] =
            ICrossChainController.ChainConfig({ localAdapter: address(origin.adapter), remoteAdapter: address(0) });

        vm.prank(address(origin.dao));
        vm.expectRevert(abi.encodeWithSelector(Errors.INCOMPLETE_ADAPTER_CONFIG.selector, UNCONFIGURED_CHAIN_ID));
        origin.controller.updateConfig(chainIds, configs);
    }

    /// @notice Clearing a lane removes BOTH directions: the outbound route and
    ///         the inbound authorisation of the local adapter.
    function test_auth_clearingALaneRemovesBothDirections() public {
        _clearLane(destination, origin.chainId);

        assertFalse(
            destination.controller.isRegisteredLocalAdapter(address(destination.adapter), origin.chainId),
            "the local adapter must no longer be authorised inbound"
        );

        _on(destination);
        vm.prank(address(destination.dao));
        vm.expectRevert(abi.encodeWithSelector(Errors.ADAPTER_NOT_CONFIGURED.selector, origin.chainId));
        destination.controller.forwardMessage(origin.chainId, GAS_LIMIT, _emptyPayload());
    }

    // -------------------------------------------------------------------------
    // Incident response.
    //
    // `PAUSE` and `UNPAUSE` are deliberately separate permissions so a guardian
    // trusted only to freeze cannot reopen the paths mid-incident. The unit
    // suite pins that against the DAO mock; this pins it against a real
    // `PermissionManager`, which is where the separation actually lives.
    // -------------------------------------------------------------------------

    /// @notice The guardian can freeze the message paths.
    function test_auth_guardianCanPauseAndThatStopsInboundExecution() public {
        _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));

        _on(destination);
        vm.prank(guardian);
        destination.controller.pause();
        _on(origin);

        (, bool success) = _deliverNext(origin, destination);

        assertFalse(success, "a paused controller must refuse the delivery");

        // WHY it was refused, not merely that it was: the happy-path suite
        // proves this lane delivers when unpaused, but only the revert reason
        // rules out the delivery having failed for some unrelated cause.
        assertEq(
            origin.router.lastDeliveryReturnData(),
            abi.encodeWithSignature("Error(string)", "Pausable: paused"),
            "the pause must be what refused it"
        );

        assertEq(destination.target.cancellations(), 0, "no action may execute while paused");

        // And it is only the pause: unpausing lets the very same queued message
        // through, so nothing about the message itself was wrong.
        _on(destination);
        vm.prank(address(destination.dao));
        destination.controller.unpause();
        _on(origin);

        (, bool afterUnpause) = _deliverNext(origin, destination);

        assertTrue(afterUnpause, "the same message must deliver once unpaused");
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice The guardian holds `PAUSE` and NOT `UNPAUSE`, so it cannot reopen
    ///         what it froze -- only the DAO can.
    function test_auth_guardianCannotUnpause() public {
        _on(destination);

        vm.prank(guardian);
        destination.controller.pause();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(destination.dao),
                address(destination.controller),
                guardian,
                Permissions.UNPAUSE_PERMISSION_ID
            )
        );
        destination.controller.unpause();

        // The DAO can.
        vm.prank(address(destination.dao));
        destination.controller.unpause();

        assertFalse(destination.controller.paused());
    }
}
