// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import { PluginUUPSUpgradeable } from "@aragon/osx-commons-contracts/src/plugin/PluginUUPSUpgradeable.sol";
import { Action, IExecutor } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import { IBaseAdapter } from "./adapters/IBaseAdapter.sol";
import { ICrossChainController } from "./ICrossChainController.sol";
import { Errors } from "./lib/Errors.sol";
import { Permissions } from "./lib/Permissions.sol";

import { TransactionLib, Transaction, TransactionRecord, TransactionState } from "./lib/Transaction.sol";

/// @title CrossChainController
/// @notice The entry point for sending and receiving a message cross chain.
/// @custom:security-contact sirt@aragon.org
contract CrossChainController is ICrossChainController, PluginUUPSUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using TransactionLib for Transaction;
    using TransactionLib for bytes;

    /// @notice Monotonic counter stamped into every outbound transaction, so
    ///         two identical messages never share a `txId`.
    uint256 internal _currentTxNonce;

    /// @notice txId -> stored message: its state and when it was delivered.
    mapping(bytes32 => TransactionRecord) private _transactions;

    /// @notice standard chain id -> adapter configuration.
    mapping(uint256 => ChainConfig) public chainToAdapter;

    /// @notice The executor that inbound payloads are executed on.
    address public executor;

    /// @notice Gas withheld from an inbound payload so the failure path can
    ///         record it as `Delivered`.
    /// @dev Without a reserve the EVM hands the payload 63/64 of what is left
    ///      and keeps only 1/64, which may be too little to store `Delivered`
    ///      AND emit - the whole delivery then reverts and leaves NO record.
    ///      The message is unreachable by `retryMessage` and `cancelMessage`,
    ///      recoverable only through the bridge's own manual execution.
    ///
    ///      Size it against the payload, not once and for all: the failure
    ///      branch emits the full encoded transaction plus the revert reason,
    ///      so its cost grows with payload size. `0` disables the reserve.
    ///      See `initialize`.
    uint256 public minFailedMessageGas;

    /// @notice Restricts a function to local adapters registered via `updateConfig`.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyLocalAdapter(uint256 _srcChainId) {
        if (!isRegisteredLocalAdapter(msg.sender, _srcChainId)) {
            revert Errors.CALLER_NOT_LOCAL_ADAPTER(msg.sender);
        }

        _;
    }

    /// @notice Initializes the plugin behind a UUPS proxy.
    /// @dev Called once by the plugin setup right after the proxy is deployed.
    /// @param _dao The DAO acting as this contract's permission manager.
    /// @param _executor The executor inbound payloads are executed on. Pass the
    ///        DAO itself to keep execution on the DAO.
    /// @param _minFailedMessageGas Gas withheld from the payload so the `catch`
    ///        in `receiveMessage` can always record a failed message as
    ///        `Delivered`. **45000 is a good enough value.**
    function initialize(IDAO _dao, address _executor, uint256 _minFailedMessageGas) external initializer {
        __PluginUUPSUpgradeable_init(_dao);
        __Pausable_init();

        _setExecutor(_executor);
        _setMinFailedMessageGas(_minFailedMessageGas);
    }

    /// @notice Accepts native pre-funding used to pay bridge fees.
    receive() external payable { }

    // -------------------------------------------------------------------------
    // ====================== Configuration ======================
    // -------------------------------------------------------------------------

    /// @notice Freezes the message paths (forward / receive / retry).
    function pause() external virtual auth(Permissions.PAUSE_PERMISSION_ID) {
        _pause();
    }

    /// @notice Resumes the message paths.
    /// @dev Gated by its own permission (not `PAUSE_PERMISSION`) so a guardian
    ///      trusted only to freeze cannot reopen the paths mid-incident.
    function unpause() external virtual auth(Permissions.UNPAUSE_PERMISSION_ID) {
        _unpause();
    }

    /// @notice Allows to update configuration per chain.
    /// @dev Pass an all-zero `ChainConfig` to clear/remove
    ///      or a fully set one to configure it. `localAdapter` must be a
    ///      deployed contract; `remoteAdapter` lives on another chain and
    ///      cannot be validated here.
    /// @param _chainIds The standard chain ids to configure. These are the
    ///        REMOTE (destination/origin) chain ids. Note that it allows
    ///        to set config for this chain, allowing crosschain messages
    ///        to occur from chain x to chain x.
    /// @param _configs The configuration per chain id.
    function updateConfig(uint256[] memory _chainIds, ChainConfig[] memory _configs)
        public
        virtual
        auth(Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID)
    {
        if (_chainIds.length != _configs.length) {
            revert Errors.INVALID_LENGTH_MISMATCH();
        }

        for (uint256 i = 0; i < _chainIds.length; i++) {
            uint256 chainId = _chainIds[i];
            if (chainId == 0) revert Errors.INVALID_CHAIN_ID();

            ChainConfig memory newConfig = _configs[i];

            bool hasLocal = newConfig.localAdapter != address(0);
            bool hasRemote = newConfig.remoteAdapter != address(0);

            if (hasLocal != hasRemote) {
                revert Errors.INCOMPLETE_ADAPTER_CONFIG(chainId);
            }

            // `remoteAdapter` lives on another chain and cannot be checked here.
            if (hasLocal && newConfig.localAdapter.code.length == 0) {
                revert Errors.HAS_NO_CODE(newConfig.localAdapter);
            }

            chainToAdapter[chainId] = newConfig;

            emit ConfigUpdated(chainId, newConfig.localAdapter, newConfig.remoteAdapter);
        }
    }

    /// @notice Updates the gas withheld for recording a failed message.
    /// @param _minFailedMessageGas The new reserve.
    function updateMinFailedMessageGas(uint256 _minFailedMessageGas)
        public
        virtual
        auth(Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID)
    {
        _setMinFailedMessageGas(_minFailedMessageGas);
    }

    /// @notice Repoints this controller at a different executor.
    /// @dev Only the presence of code is validated; authorization is not and
    ///      cannot be checked here. The new executor must allow this controller
    ///      to call `execute` before the next inbound payload needs to run -
    ///      bundling that into the same proposal is the safe way. Messages
    ///      arriving in the gap are not lost: they are recorded as `Delivered`
    ///      and can be retried once authorization is in place.
    /// @param _executor The new executor address. Must be a contract.
    function updateExecutor(address _executor) public virtual auth(Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID) {
        _setExecutor(_executor);
    }

    /// @notice Moves pre-funded fee assets out of this contract.
    /// @dev This contract is the fee payer: under `delegatecall` the bridge call
    ///      is made by this account, so fees come straight from here. The
    ///      protocol never routes funds through the adapter, and this function
    ///      can recover anything held here. Note that assets transferred
    ///      DIRECTLY to an adapter are stranded - adapters have no rescue path.
    /// @param _token The asset to move; `address(0)` for native currency.
    /// @param _to The recipient (typically the DAO).
    /// @param _amount The amount to move.
    function sweep(address _token, address _to, uint256 _amount) public virtual auth(Permissions.SWEEP_PERMISSION_ID) {
        if (_to == address(0)) revert Errors.ZERO_ADDRESS();

        if (_token == address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = _to.call{ value: _amount }("");
            if (!ok) revert Errors.NATIVE_TRANSFER_FAILED(_to, _amount);
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }

        emit Swept(_token, _to, _amount);
    }

    /// @inheritdoc ICrossChainController
    /// @dev Executes the adapter's send code IN THIS CONTRACT'S CONTEXT. The
    ///      bridge fee is paid straight from this contract's balance, and the
    ///      bridge attributes the message to this contract's address.
    function forwardMessage(uint256 _destinationChainId, uint256 _gasLimit, bytes memory _message)
        public
        virtual
        override
        whenNotPaused
        auth(Permissions.FORWARD_MESSAGE_PERMISSION_ID)
        returns (bytes32)
    {
        ChainConfig memory config = _validatedConfig(_destinationChainId);

        bytes memory encodedTx = Transaction({
                nonce: ++_currentTxNonce,
                origin: msg.sender,
                controller: address(this),
                originChainId: block.chainid,
                destinationChainId: _destinationChainId,
                message: _message
            }).encode();

        (uint256 messageId, uint256 fee) = _dispatch(config, _destinationChainId, _gasLimit, encodedTx);

        emit MessageForwarded(
            _destinationChainId,
            messageId,
            encodedTx.id(),
            encodedTx,
            config.localAdapter,
            config.remoteAdapter,
            _gasLimit,
            fee
        );

        return encodedTx.id();
    }

    // -------------------------------------------------------------------------
    // Receiving
    // -------------------------------------------------------------------------

    /// @inheritdoc ICrossChainController
    /// @dev Only a registered local adapter may call this. The adapter is
    ///      responsible for having authenticated the remote sender. This
    ///      contract is bridge agnostic, so `_messageId` is untrusted and only
    ///      ever emitted, never used for control flow.
    function receiveMessage(uint256 _messageId, bytes memory _encodedTx, uint256 _originChainId)
        public
        virtual
        override
        whenNotPaused
        onlyLocalAdapter(_originChainId)
        returns (bytes32 txId)
    {
        // Decode tx and get its id.
        Transaction memory transaction = _encodedTx.decode();
        txId = transaction.id();

        // Don't fully trust the adapter/bridge.
        if (transaction.originChainId != _originChainId || transaction.destinationChainId != block.chainid) {
            revert Errors.INCORRECT_CHAIN_MISMATCH();
        }

        TransactionRecord storage record = _transactions[txId];

        // Either message is already delivered or executed.
        // If delivered, but execution failed, call retry.
        if (record.state != TransactionState.None) {
            revert Errors.MESSAGE_ALREADY_DELIVERED_OR_EXECUTED(txId);
        }

        record.state = TransactionState.Executed;

        // Stamped on both branches: this is when the message arrived, whether
        // or not its actions executed. Shares a slot with `state`.
        record.bridgedAt = SafeCast.toUint120(block.timestamp);

        // Reserve gas for the `catch` block before running the payload.
        //
        // The EVM would otherwise hand the payload 63/64 of what is left and
        // keep only 1/64, which an out-of-gas payload can leave too small to
        // store the state and emit - reverting the whole delivery and recording
        // nothing. The message did arrive, so it must be recorded as
        // `Delivered` and stay retryable or cancellable.
        uint256 reserve = minFailedMessageGas;
        uint256 gasLimit = gasleft();
        unchecked {
            if (gasLimit < reserve) revert Errors.INSUFFICIENT_GAS(gasLimit, reserve);
            gasLimit -= reserve;
        }

        // The self-call also contains payload decoding, so a malformed payload
        // is captured for retry rather than reverting the bridge delivery.
        try this.executeActions{ gas: gasLimit }(txId, transaction.message) {
            emit MessageReceived(_originChainId, _messageId, txId, _encodedTx);
        } catch (bytes memory reason) {
            record.state = TransactionState.Delivered;

            emit MessageExecutionFailed(_originChainId, _messageId, txId, _encodedTx, reason);
        }
    }

    /// @inheritdoc ICrossChainController
    /// @dev Reverts (bubbling the failure) if the retry fails again, so the
    ///      stored message stays pending.
    function retryMessage(bytes memory _encodedTx)
        public
        virtual
        override
        whenNotPaused
        auth(Permissions.RETRY_MESSAGE_PERMISSION_ID)
    {
        // Normalize before hashing, exactly like `receiveMessage`: the record
        // is keyed by the hash of the canonical re-encoding, so any decodable
        // representation of the same transaction resolves to the same txId.
        Transaction memory transaction = _encodedTx.decode();
        bytes32 txId = transaction.id();
        TransactionRecord storage record = _transactions[txId];

        // Transaction must be delivered, but not executed in order to retry.
        if (record.state != TransactionState.Delivered) {
            revert Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS(txId);
        }

        record.state = TransactionState.Executed;

        this.executeActions(txId, transaction.message);

        emit MessageRetried(txId);
    }

    /// @notice Cancels a delivered-but-failed message so it can never execute.
    /// @dev Only a `Delivered` (failed, pending-retry) message can be cancelled.
    ///      The `txId` stays occupied (state becomes `Cancelled`, not `None`),
    ///      so the same message can never be re-delivered or retried afterwards.
    /// @param _encodedTx The encoded tx that must be cancelled.
    function cancelMessage(bytes memory _encodedTx) public virtual auth(Permissions.CANCEL_MESSAGE_PERMISSION_ID) {
        // Normalized like `receiveMessage`/`retryMessage`, so the emergency
        // path accepts any decodable representation of the stored message.
        bytes32 txId = _encodedTx.decode().id();
        TransactionRecord storage record = _transactions[txId];

        if (record.state != TransactionState.Delivered) {
            revert Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS(txId);
        }

        record.state = TransactionState.Cancelled;

        emit MessageCancelled(txId);
    }

    /// @notice Decodes and runs an authenticated payload on the executor.
    /// @dev External only so `receiveMessage` can wrap it in `try/catch`;
    ///      callable exclusively by this contract. Decoding lives here so a
    ///      malformed payload is captured rather than reverting the delivery.
    ///      `retryMessage` self-calls it too, deliberately WITHOUT `try/catch`,
    ///      so a failed retry reverts and the message stays `Delivered`.
    /// @param _txId The tx id passed to the executor as its call id.
    /// @param _payload The encoded Action[] message.
    function executeActions(bytes32 _txId, bytes memory _payload) external {
        if (msg.sender != address(this)) {
            revert Errors.CALLER_NOT_SELF(msg.sender);
        }

        Action[] memory actions = abi.decode(_payload, (Action[]));

        IExecutor(executor).execute(_txId, actions, 0);
    }

    // -------------------------------------------------------------------------
    // ====================== Public View Functions ======================
    // -------------------------------------------------------------------------

    /// @notice Quotes the bridge fee for a send.
    /// @param _destinationChainId The standard chain id of remote chain.
    /// @param _gasLimit The gas limit that will be used for crosschain message execution.
    /// @param _message The encoded Action[] message.
    /// @return feeToken The fee token (`address(0)` for native).
    /// @return fee The required fee amount.
    /// @return available The balance this contract currently holds of `feeToken`.
    function quoteFee(uint256 _destinationChainId, uint256 _gasLimit, bytes memory _message)
        public
        view
        virtual
        returns (address feeToken, uint256 fee, uint256 available)
    {
        ChainConfig memory config = _validatedConfig(_destinationChainId);

        // Quote the SAME bytes `forwardMessage` will send.
        bytes memory encodedTx = Transaction({
                nonce: _currentTxNonce + 1,
                origin: msg.sender,
                controller: address(this),
                originChainId: block.chainid,
                destinationChainId: _destinationChainId,
                message: _message
            }).encode();

        (feeToken, fee) =
            IBaseAdapter(config.localAdapter).quoteFee(config.remoteAdapter, _destinationChainId, _gasLimit, encodedTx);

        available = feeToken == address(0) ? address(this).balance : IERC20(feeToken).balanceOf(address(this));
    }

    /// @notice Whether an address is currently registered as a local adapter.
    /// @param _adapter The address to check.
    /// @param _chainId The chain id of remote chain.
    function isRegisteredLocalAdapter(address _adapter, uint256 _chainId) public view returns (bool) {
        return chainToAdapter[_chainId].localAdapter == _adapter;
    }

    /// @notice Returns everything stored about a transaction.
    /// @param _txId The tx id.
    /// @return The record; all-zero for a txId that was never delivered.
    function getTransaction(bytes32 _txId) public view virtual returns (TransactionRecord memory) {
        return _transactions[_txId];
    }

    /// @notice Checks if an interface is supported by this or its parent contract.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return _interfaceId == type(ICrossChainController).interfaceId || super.supportsInterface(_interfaceId);
    }

    // -------------------------------------------------------------------------
    // ====================== Internal/Private Functions ======================
    // -------------------------------------------------------------------------

    /// @notice `delegatecall`s the local adapter's send path and
    ///         decodes its `(messageId, fee)` return.
    function _dispatch(
        ChainConfig memory _config,
        uint256 _destinationChainId,
        uint256 _gasLimit,
        bytes memory _encodedTx
    )
        internal
        virtual
        returns (uint256 messageId, uint256 fee)
    {
        bytes memory encodedCall = abi.encodeCall(
            IBaseAdapter.sendMessage, (_config.remoteAdapter, _destinationChainId, _gasLimit, _encodedTx)
        );

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = _config.localAdapter.delegatecall(encodedCall);

        if (!success) {
            if (returndata.length == 0) revert Errors.MESSAGE_SEND_FAILED();

            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }

        // Make sure adapter returns the right length parameters.
        if (returndata.length < 64) revert Errors.MESSAGE_SEND_FAILED();

        (messageId, fee) = abi.decode(returndata, (uint256, uint256));
    }

    /// @notice Shared by `initialize` and `updateExecutor`.
    /// @dev Only checks that the target has code. It cannot verify that the new
    ///      executor authorizes this controller to call `execute` on it, so a
    ///      repoint that skips that step leaves every inbound payload failing
    ///      on execution. Deliveries still land as `Delivered` and surface as
    ///      `MessageExecutionFailed`, so they stay retryable once fixed.
    function _setExecutor(address _executor) internal {
        if (_executor.code.length == 0) revert Errors.HAS_NO_CODE(_executor);

        emit ExecutorUpdated(executor, _executor);

        executor = _executor;
    }

    /// @notice Shared by `initialize` and `updateMinFailedMessageGas`.
    /// @dev `0` is a valid value and disables the reserve.
    function _setMinFailedMessageGas(uint256 _minFailedMessageGas) internal virtual {
        emit MinFailedMessageGasUpdated(minFailedMessageGas, _minFailedMessageGas);

        minFailedMessageGas = _minFailedMessageGas;
    }

    /// @notice Loads and validates the lane configuration for a destination.
    function _validatedConfig(uint256 _destinationChainId) internal view virtual returns (ChainConfig memory config) {
        config = chainToAdapter[_destinationChainId];

        if (config.localAdapter == address(0) || config.remoteAdapter == address(0)) {
            revert Errors.ADAPTER_NOT_CONFIGURED(_destinationChainId);
        }
    }

    /// @notice This empty reserved space is put in place to allow future versions to add
    ///         new variables without shifting down storage in the inheritance chain.
    uint256[45] private __gap;
}
