// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { IBaseAdapter } from "@src/adapters/IBaseAdapter.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";

import { IExecutor, Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

/// @notice A loopback adapter for the chain-x-to-chain-x lane: `sendMessage`
///         hands the envelope back into the SAME controller's receive path
///         instead of to a bridge, so a send and its delivery happen in one
///         transaction on one chain.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
///
///      WHY IT IMPLEMENTS `IBaseAdapter` AND NOT `BaseAdapter`. `BaseAdapter`
///      separates its two paths by EXECUTION CONTEXT — the send path asserts
///      `address(this) == CROSS_CHAIN_CONTROLLER` (delegatecall), the receive
///      path asserts `address(this) == _selfAddress` (plain `CALL`). A loopback
///      needs both in one hop, and those are mutually exclusive within a frame,
///      so `BaseAdapter` structurally cannot express this shape.
///
///      WHY IT RUNS THE PAYLOAD ITSELF instead of calling `receiveMessage`.
///      The lane exists to serve the L2-to-L1 governance shape, where the
///      controller's executor is the DAO and the send is initiated from inside a
///      DAO `execute` frame. Routing the delivery back through `receiveMessage`
///      would re-enter that still-open frame: a `nonReentrant` executor rejects
///      the inner call, `receiveMessage`'s `try/catch` absorbs the revert, and
///      the message strands as `Delivered` with no error surfaced. Calling the
///      executor directly keeps the payload out of that nesting.
///
///      WHAT THAT GIVES UP. Everything `receiveMessage` does: the envelope's
///      chain ids are not re-verified, no `txId` is derived, no `_transactions`
///      record is written, replay is not guarded, and a reverting payload is NOT
///      captured as `Delivered` — it bubbles and reverts the send. Tests
///      asserting on delivery state, replay or retry need a different fixture.
///
///      The send path touches NO storage — every field is `immutable` — because
///      under `delegatecall` an `SSTORE` here would land in the CONTROLLER's
///      slots.
contract SameChainAdapter is IBaseAdapter {
    /// @notice The controller that owns this adapter. On a loopback lane it is
    ///         both the origin and the destination controller.
    address private immutable CONTROLLER;

    /// @notice The bridge message id `sendMessage` returns.
    uint256 private immutable MESSAGE_ID;

    /// @notice The executor the payload's actions are run on.
    address private immutable EXECUTOR;

    /// @param controller_ The owning `CrossChainController` — origin AND
    ///        destination, since the lane loops back to the same chain.
    /// @param executor_ The executor the payload runs on. Must authorize THIS
    ///        ADAPTER to call `execute` — for the dedicated `Executor`, that
    ///        means the adapter owns it.
    /// @param messageId_ The bridge message id `sendMessage` returns.
    constructor(address controller_, address executor_, uint256 messageId_) {
        if (controller_ == address(0)) revert Errors.ZERO_ADDRESS();
        if (executor_ == address(0)) revert Errors.ZERO_ADDRESS();

        CONTROLLER = controller_;
        EXECUTOR = executor_;
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

    /// @inheritdoc IBaseAdapter
    /// @dev Delegatecalled by `CrossChainController._dispatch`, so this frame
    ///      runs AS THE CONTROLLER: `address(this) == CONTROLLER`. That is what
    ///      lets it call `EXECUTOR.execute` for a controller-owned `Executor` —
    ///      `onlyOwner` sees the controller, not the adapter.
    ///
    ///      The payload is unwrapped here rather than by `receiveMessage`: the
    ///      envelope `forwardMessage` built is decoded back to a `Transaction`,
    ///      and its `message` field to the `Action[]` the executor runs. The
    ///      `txId` is the envelope hash, matching what `forwardMessage` returns,
    ///      so the executor's `Executed` event carries the same id the send
    ///      reports.
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
        toNativeChainId(_destinationChainId);

        Transaction memory transaction = TransactionLib.decode(_message);
        Action[] memory actions = abi.decode(transaction.message, (Action[]));

        IExecutor(EXECUTOR).execute(TransactionLib.id(_message), actions, 0);

        // No fee: a loopback has no router to pay.
        return (MESSAGE_ID, 0);
    }

    function executor() external view returns (address) {
        return EXECUTOR;
    }

    /// @inheritdoc IBaseAdapter
    function CROSS_CHAIN_CONTROLLER() external view override returns (address) {
        return CONTROLLER;
    }
}
