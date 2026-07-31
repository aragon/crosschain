// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { Errors } from "../lib/Errors.sol";
import { CrossChainController } from "../CrossChainController.sol";

import { IBaseAdapter } from "./IBaseAdapter.sol";

/// @title BaseAdapter
/// @notice Shared logic for bridge adapters owned by a `CrossChainController`.
/// @custom:security-contact sirt@aragon.org
abstract contract BaseAdapter is IBaseAdapter {
    /// @notice The address of crosschain controller.
    address public immutable override CROSS_CHAIN_CONTROLLER;

    /// @notice This adapter's own address, captured at construction.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _selfAddress;

    /// @notice A standard chain id paired with the remote trusted sender.
    /// @param standardChainId The standard chain id of the remote chain.
    /// @param trustedRemote The remote `CrossChainController` allowed to
    ///        originate messages for that chain.
    struct TrustedRemoteConfig {
        uint256 standardChainId;
        address trustedRemote;
    }

    /// @notice standard chain id -> remote trusted address allowed
    ///         to originate messages for that chain.
    /// @dev IMPORTANT: Receive-path only. The receive path runs as the adapter (`CALL`), so this
    ///      reads adapter storage; under the send path's `delegatecall` the same slots
    ///      would resolve against the controller's storage instead.
    mapping(uint256 => address) internal _trustedRemotes;

    /// @notice Emitted when a trusted remote is set or cleared.
    event TrustedRemoteSet(uint256 indexed chainId, address trustedRemote);

    /// @notice Restricts a function to being `delegatecall`ed by the owning
    ///         `CrossChainController`.
    /// @dev Under `delegatecall` from the controller, `address(this)` IS the
    ///      controller, so a direct call to the adapter fails this check.
    ///      `msg.sender` is whoever called `forwardMessage` and carries no
    ///      meaning here, so the execution *context* is what must be asserted.
    ///      Authorization of the send itself is `FORWARD_MESSAGE_PERMISSION` on
    ///      the controller.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyDelegatecallFromController() {
        if (address(this) != CROSS_CHAIN_CONTROLLER) {
            revert Errors.SEND_PATH_NOT_DELEGATECALLED(address(this));
        }
        _;
    }

    /// @param _crossChainController The LOCAL controller that owns this
    ///        adapter. The send path asserts it is running in this controller's
    ///        CONTEXT (`address(this) == CROSS_CHAIN_CONTROLLER`); the caller
    ///        itself is never checked. It is also the account the receive path
    ///        reports to.
    /// @param _trustedRemoteConfigs The remote controllers trusted to originate
    ///        messages, per standard chain id.
    constructor(address _crossChainController, TrustedRemoteConfig[] memory _trustedRemoteConfigs) {
        if (_crossChainController == address(0)) revert Errors.ZERO_ADDRESS();

        CROSS_CHAIN_CONTROLLER = _crossChainController;
        _selfAddress = address(this);

        _setTrustedRemotes(_trustedRemoteConfigs);
    }

    /// @inheritdoc IBaseAdapter
    function toNativeChainId(uint256 _chainId) public view virtual override returns (uint256);

    /// @notice The remote CONTROLLER trusted to originate messages for a chain.
    /// @param _chainId The standard chain id.
    /// @return The trusted remote controller address, or zero if unset.
    function trustedRemote(uint256 _chainId) public view returns (address) {
        return _trustedRemotes[_chainId];
    }

    /// @notice Hands an authenticated inbound message to the controller.
    /// @dev The caller must have already verified the remote sender.
    /// @param _messageId The bridge-level message identifier.
    /// @param _payload The encoded payload message.
    /// @param _originChainId The standard chain id the message came from.
    function _forwardMessage(uint256 _messageId, bytes memory _payload, uint256 _originChainId) internal {
        // Guarantees the controller sees this adapter as `msg.sender`, never a
        // contract that reached this code through `delegatecall`.
        if (address(this) != _selfAddress) {
            revert Errors.DELEGATE_CALL_FORBIDDEN(address(this), _selfAddress);
        }

        CrossChainController(payable(CROSS_CHAIN_CONTROLLER)).receiveMessage(_messageId, _payload, _originChainId);
    }

    /// @notice Registers the remote controllers trusted to originate messages.
    /// @dev A zero `trustedRemote` leaves the chain unset. Implementations MUST
    ///      reject a zero sender so an unset chain can never authenticate.
    function _setTrustedRemotes(TrustedRemoteConfig[] memory _trustedRemoteConfigs) internal {
        for (uint256 i = 0; i < _trustedRemoteConfigs.length; i++) {
            uint256 chainId = _trustedRemoteConfigs[i].standardChainId;
            if (chainId == 0) revert Errors.INVALID_CHAIN_ID();

            address trustedRemote_ = _trustedRemoteConfigs[i].trustedRemote;
            _trustedRemotes[chainId] = trustedRemote_;

            emit TrustedRemoteSet(chainId, trustedRemote_);
        }
    }
}
