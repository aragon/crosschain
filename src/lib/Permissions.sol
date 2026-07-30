// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/// @title Permissions
/// @notice The permission ids used across the cross-chain contracts.
/// @custom:security-contact sirt@aragon.org
library Permissions {
    /// @notice Permission to change how the controller is wired: its per-chain
    ///         lane config and its executor.
    bytes32 internal constant MANAGE_CONTROLLER_CONFIG_PERMISSION_ID = keccak256("MANAGE_CONTROLLER_CONFIG_PERMISSION");

    /// @notice Permission to forward a message to a remote chain.
    bytes32 internal constant FORWARD_MESSAGE_PERMISSION_ID = keccak256("FORWARD_MESSAGE_PERMISSION");

    /// @notice Permission to retry a message whose execution reverted on
    ///         arrival. The setup grants it to ANY_ADDR: the payload was
    ///         already authenticated by the bridge, and the holder must NEVER
    ///         be the executor configured on the controller (nor the DAO when
    ///         `executor = dao`) -- `retryMessage` calls back into the
    ///         executor, so such a holder would re-enter `execute` and the
    ///         reentrancy guard would make every retry revert.
    bytes32 internal constant RETRY_MESSAGE_PERMISSION_ID = keccak256("RETRY_MESSAGE_PERMISSION");

    /// @notice Permission to cancel a delivered-but-failed message so it can
    ///         never be retried. Intended for the DAO and/or an ops multisig.
    bytes32 internal constant CANCEL_MESSAGE_PERMISSION_ID = keccak256("CANCEL_MESSAGE_PERMISSION");

    /// @notice Permission to move pre-funded fee assets out of this contract.
    bytes32 internal constant SWEEP_PERMISSION_ID = keccak256("SWEEP_PERMISSION");

    /// @notice Permission to pause the message paths
    ///         (forward / receive / retry). Cancelling stays available while
    ///         paused, so bad messages can be neutralised during an incident.
    bytes32 internal constant PAUSE_PERMISSION_ID = keccak256("PAUSE_PERMISSION");

    /// @notice Permission to unpause the message paths.
    bytes32 internal constant UNPAUSE_PERMISSION_ID = keccak256("UNPAUSE_PERMISSION");

    /// @notice Permission to upgrade the controller to a new implementation.
    bytes32 internal constant UPGRADE_PLUGIN_PERMISSION_ID = keccak256("UPGRADE_PLUGIN_PERMISSION");

    /// @notice The DAO's own execute permission. Held BY the controller ON the
    ///         DAO, so inbound messages can be executed when the DAO itself is
    ///         the configured executor.
    /// @dev Mirrors `DAO.EXECUTE_PERMISSION_ID`; redeclared here so the plugin
    ///      setup does not have to import the full `DAO` contract.
    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");
}
