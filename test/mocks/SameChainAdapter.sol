// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { IBaseAdapter } from "@src/adapters/IBaseAdapter.sol";
import { ICrossChainController } from "@src/ICrossChainController.sol";
import { Errors } from "@src/lib/Errors.sol";

/// @notice A loopback adapter for the chain-x-to-chain-x lane: `sendMessage`
///         hands the envelope back into the SAME controller's receive path
///         instead of to a bridge, so a send and its delivery happen in one
///         transaction on one chain.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
///
///      WHY IT IMPLEMENTS `IBaseAdapter` AND NOT `BaseAdapter`.
///      `BaseAdapter` separates the two paths by EXECUTION CONTEXT:
///
///        - `onlyDelegatecallFromController` requires
///          `address(this) == CROSS_CHAIN_CONTROLLER` (send path: reached only
///          by `delegatecall`, so `address(this)` is the controller).
///        - `_forwardMessage` requires `address(this) == _selfAddress`
///          (receive path: reached only by a plain `CALL`, so `address(this)` is
///          the adapter).
///
///      A loopback needs both in one logical hop: it is delegatecalled by
///      `forwardMessage`, and from there the envelope must enter
///      `receiveMessage` as the adapter. Those two assertions are mutually
///      exclusive within a single frame, so `BaseAdapter` structurally cannot
///      express this shape. Implementing the bare interface is what makes the
///      lane reachable at all.
///
///      The send path touches NO storage — every field is `immutable` — because
///      under `delegatecall` an `SSTORE` here would land in the CONTROLLER's
///      slots.
contract SameChainAdapter is IBaseAdapter {
    /// @notice The controller that owns this adapter. On a loopback lane it is
    ///         both the origin and the destination controller.
    address private immutable CONTROLLER;

    /// @notice This contract's own address, captured at construction.
    /// @dev The delegatecalled send frame needs this to call BACK into the
    ///      adapter. It cannot use `address(this)` for that: in that frame
    ///      `address(this)` is the controller. See `sendMessage`.
    address private immutable SELF_ADDRESS;

    /// @notice The bridge message id `sendMessage` returns.
    uint256 private immutable MESSAGE_ID;

    /// @param controller_ The owning `CrossChainController` — origin AND
    ///        destination, since the lane loops back to the same chain.
    /// @param messageId_ The bridge message id `sendMessage` returns.
    constructor(address controller_, uint256 messageId_) {
        if (controller_ == address(0)) revert Errors.ZERO_ADDRESS();

        CONTROLLER = controller_;
        SELF_ADDRESS = address(this);
        MESSAGE_ID = messageId_;
    }

    /// @inheritdoc IBaseAdapter
    function toNativeChainId(uint256 _chainId) public view override returns (uint256) {
        if (_chainId != block.chainid) revert Errors.UNKNOWN_CHAIN_ID(_chainId);
        return _chainId;
    }

    /// @inheritdoc IBaseAdapter
    function fromNativeChainId(uint256 _chainId) public view override returns (uint256) {
        if (_chainId != block.chainid) revert Errors.UNKNOWN_NATIVE_CHAIN_ID(_chainId);
        return _chainId;
    }

    /// @inheritdoc IBaseAdapter
    function quoteFee(address _receiver, uint256 _destinationChainId, uint256 _gasLimit, bytes calldata _message)
        external
        view
        override
        returns (address, uint256)
    {
        (_receiver, _gasLimit, _message);

        // Reverts if not set.
        toNativeChainId(_destinationChainId);

        return (address(0), 0);
    }

    function sendMessage(address _receiver, uint256 _destinationChainId, uint256, bytes calldata _message)
        external
        payable
        override
        returns (uint256, uint256)
    {
        if (address(this) != CONTROLLER) {
            revert Errors.SEND_PATH_NOT_DELEGATECALLED(address(this));
        }

        if (_receiver == address(0)) revert Errors.ZERO_ADDRESS();

        // Reverts if not set.
        uint256 nativeChainId = toNativeChainId(_destinationChainId);

        SameChainAdapter(SELF_ADDRESS).deliver(MESSAGE_ID, _message, fromNativeChainId(nativeChainId));

        // No fee: a loopback has no router to pay.
        return (MESSAGE_ID, 0);
    }

    function deliver(uint256 _messageId, bytes calldata _encodedTx, uint256 _originChainId) external {
        if (address(this) != SELF_ADDRESS) {
            revert Errors.DELEGATE_CALL_FORBIDDEN(address(this), SELF_ADDRESS);
        }

        if (msg.sender != CONTROLLER) {
            revert Errors.CALLER_NOT_LOCAL_ADAPTER(msg.sender);
        }

        ICrossChainController(CONTROLLER).receiveMessage(_messageId, _encodedTx, _originChainId);
    }

    /// @inheritdoc IBaseAdapter
    function CROSS_CHAIN_CONTROLLER() external view override returns (address) {
        return CONTROLLER;
    }
}
