// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

library Errors {
    // ---------------------------------------------------------------------
    // Generic / configuration
    // ---------------------------------------------------------------------

    /// @notice Thrown when two array arguments meant to be read in lockstep
    ///         have different lengths.
    error INVALID_LENGTH_MISMATCH();

    /// @notice Thrown when a chain id of `0` is used. `0` is reserved as the
    ///         "unset" marker of the `chainToAdapter` and chain-selector maps.
    error INVALID_CHAIN_ID();

    /// @notice Thrown when a lane is only partially configured. A lane is
    ///         either fully set (`localAdapter`, `remoteAdapter` and
    ///         `bridgeChainId` all non-zero) or fully cleared.
    error INCOMPLETE_ADAPTER_CONFIG(uint256 chainId);

    /// @notice Thrown when forwarding to a chain whose lane is unset. Covers a
    ///         missing local adapter, a missing remote adapter, and a missing
    ///         bridge-native chain id (which would otherwise send to
    ///         selector `0`).
    error ADAPTER_NOT_CONFIGURED(uint256 chainId);

    /// @notice Thrown when an address that must be a contract
    ///         has no deployed code.
    error HAS_NO_CODE(address account);

    /// @notice Thrown when `address(0)` is passed where a
    ///         real address is required.
    error ZERO_ADDRESS();

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    /// @notice Thrown when `ccipReceive` is called by anything other than the
    ///         configured CCIP router.
    error CALLER_NOT_CCIP_ROUTER();

    /// @notice Thrown when `receiveMessage` is called by anything other than a
    ///         local adapter registered through `updateConfig`.
    error CALLER_NOT_LOCAL_ADAPTER(address caller);

    /// @notice Thrown when the send path is executed outside a `delegatecall`
    ///         from the owning `CrossChainController`, i.e. when
    ///         `address(this) != CROSS_CHAIN_CONTROLLER`. Calling an adapter's
    ///         `sendMessage` directly would use the adapter's own (empty)
    ///         balance and make the bridge see the adapter as the sender, which
    ///         the far side does not trust.
    error SEND_PATH_NOT_DELEGATECALLED(address context);

    /// @notice Thrown when a RECEIVE-path function — which legitimately reads
    ///         the adapter's own storage — is reached in a foreign execution
    ///         context, i.e. `address(this) != _selfAddress`.
    error DELEGATE_CALL_FORBIDDEN(address context, address self);

    /// @notice Thrown when the internal self-call entry point
    ///         is called externally.
    error CALLER_NOT_SELF(address caller);

    // ---------------------------------------------------------------------
    // Trusted remotes
    // ---------------------------------------------------------------------

    /// @notice Thrown when an inbound message's sender is not the trusted
    ///         remote registered for its origin chain.
    error REMOTE_NOT_TRUSTED();

    // ---------------------------------------------------------------------
    // Chain id mapping
    // ---------------------------------------------------------------------

    /// @notice Thrown when a standard chain id has no bridge-native counterpart.
    error UNKNOWN_CHAIN_ID(uint256 chainId);

    /// @notice Thrown when a bridge-native chain id has no standard counterpart.
    error UNKNOWN_NATIVE_CHAIN_ID(uint256 nativeChainId);

    /// @notice Thrown when the bridge itself does not support the destination
    ///         chain, even though the lane is configured locally.
    error DESTINATION_CHAIN_ID_NOT_SUPPORTED(uint256 nativeChainId);

    // ---------------------------------------------------------------------
    // Fees
    // ---------------------------------------------------------------------

    /// @notice Thrown when the pre-funded fee balance is below the quoted fee.
    error INSUFFICIENT_FEE_BALANCE(address feeToken, uint256 required, uint256 available);

    /// @notice Thrown when the `delegatecall` into the local adapter's send
    ///         path failed without returning a reason to bubble.
    error MESSAGE_SEND_FAILED();

    /// @notice Thrown when native value is sent while an ERC20 fee token is
    ///         configured (the value would be stranded).
    error UNEXPECTED_NATIVE_VALUE();

    error NATIVE_TRANSFER_FAILED(address to, uint256 amount);

    // ---------------------------------------------------------------------
    // Defensive receive / retry
    // ---------------------------------------------------------------------

    /// @notice Thrown when an inbound message reuses a call id that is already
    ///         stored as delivered or executed.
    error MESSAGE_ALREADY_DELIVERED_OR_EXECUTED(bytes32 txId);

    /// @notice Thrown when an inbound message reuses a call id that is already
    ///         stored as delivered or executed.
    error MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS(bytes32 txId);

    /// @notice Thrown when message delivered to the actual chain doesn't match
    ///         the chain sender intended to send.
    error INCORRECT_CHAIN_MISMATCH();

    /// @notice Thrown by `retryMessage` when the message arrived at or before
    ///         its origin chain's retry cutoff, i.e. it belongs to a backlog
    ///         that has since been blocked.
    error MESSAGE_PREDATES_RETRY_CUTOFF(bytes32 txId, uint120 bridgedAt, uint120 cutoff);

    /// @notice Thrown when a retry cutoff is not strictly greater than the
    ///         current one, or is set in the future.
    error RETRY_CUTOFF_INVALID(uint256 originChainId, uint120 currentCutoff, uint120 newCutoff);

    /// @notice Thrown when a delivery does not carry enough gas to both attempt
    ///         the payload and reserve what the failure path needs to record it.
    /// @dev Reverting leaves the message in the bridge's failed state, where it
    ///      stays manually executable with a higher gas limit.
    error INSUFFICIENT_GAS(uint256 available, uint256 required);
}
