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

    // every message originator sends we put into an transaction and attach a nonce. It increments by one
    uint256 internal _currentTxNonce;

    /// @notice txId -> stored message: its state and when it was delivered.
    mapping(bytes32 => TransactionRecord) private _transactions;

    /// @notice standard origin chain id -> the delivery timestamp at or before
    ///         which that chain's pending messages can no longer be retried.
    /// @dev A delivered-but-failed message can only be retried if it arrived
    ///      strictly after its origin chain's cutoff (`bridgedAt > cutoff`). Raising the cutoff blocks that
    ///      chain's whole pending backlog in one call, instead of cancelling
    ///      each message individually.
    ///
    ///      Only affects the backlog. Messages still in flight are stopped by
    ///      pausing or by repointing the chain's local adapter, both of which
    ///      reject the delivery before it is ever recorded.
    mapping(uint256 => uint120) internal _retryCutoffs;

    /// @notice standard chain id -> adapter configuration.
    mapping(uint256 => ChainConfig) public chainToAdapter;

    /// @notice The executor that inbound payloads are executed on.
    address public executor;

    /// @notice Without a reserve the EVM hands the payload 63/64 of what is left
    ///      and keeps only 1/64 - not enough to store `Delivered` AND emit, so
    ///      an out-of-gas payload reverts the whole delivery and leaves NO
    ///      record. The message is then unreachable by `retryMessage` and
    ///      `cancelMessage`, recoverable only through the bridge's own manual
    ///      execution. See `initialize` for sizing.
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

    /// @notice Blocks every message from a chain that arrived at or before
    ///         `_cutoff` from being retried.
    /// @dev Does in one call what `cancelMessage` does one message at a time.
    /// @param _originChainId The standard chain id whose delivered messages are
    ///        blocked.
    /// @param _cutoff The delivery timestamp at or before which messages from
    ///        `_originChainId` can no longer be retried.
    function updateRetryCutoff(uint256 _originChainId, uint120 _cutoff)
        public
        virtual
        auth(Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID)
    {
        if (_originChainId == 0) revert Errors.INVALID_CHAIN_ID();

        uint120 currentCutoff = _retryCutoffs[_originChainId];
        if (_cutoff <= currentCutoff || _cutoff > block.timestamp) {
            revert Errors.RETRY_CUTOFF_INVALID(_originChainId, currentCutoff, _cutoff);
        }

        _retryCutoffs[_originChainId] = _cutoff;

        emit RetryCutoffUpdated(_originChainId, currentCutoff, _cutoff);
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
    /// @dev The message is routed to this executor address for execution.
    /// @param _executor The new executor address.
    function updateExecutor(address _executor) public virtual auth(Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID) {
        _setExecutor(_executor);
    }

    /// @notice Moves pre-funded fee assets out of this contract.
    /// @dev This contract is the fee payer: under `delegatecall` the bridge
    ///      call is made by this account, so the fee (native `msg.value` or an
    ///      ERC20 pulled by the router) comes straight from here. No funds are
    ///      ever handed to the adapter and none can be stranded there.
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
    ///      responsible for having authenticated the remote sender.
    ///      CrossChainController is bridge agnostic, so _messageId is only used
    ///      for emit principles only and should not be fully trusted.
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
        // Without this, the EVM hands the payload 63/64 of whatever is left and
        // keeps only 1/64. Say 101,000 gas is left and the payload needs
        // 100,000: it gets 99,421, runs out, and the `catch` is left with 1,579
        // -- too little to store the state and emit. So the whole call reverts
        // and nothing is written down.
        //
        // That is the wrong outcome. The message did arrive and its actions
        // were attempted; only the actions failed. It should be recorded as
        // `Delivered` so it can be retried or cancelled here. Holding gas back
        // guarantees the `catch` can always do that.
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

        // `originChainId` is covered by `txId` (the hash commits to every
        // field), so a retrier cannot name a different chain to dodge that
        // chain's cutoff.
        uint120 cutoff = _retryCutoffs[transaction.originChainId];
        if (record.bridgedAt <= cutoff) {
            revert Errors.MESSAGE_PREDATES_RETRY_CUTOFF(txId, record.bridgedAt, cutoff);
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

    /// @notice Decodes and executes an authenticated payload on the DAO.
    /// @dev External only so it can be wrapped in `try/catch`; callable
    ///      exclusively by this contract.
    /// @param _txId The tx Id passed to the executor.
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

    /// @notice The delivery timestamp at or before which a chain's messages can
    ///         no longer be retried.
    /// @param _originChainId The standard chain id.
    /// @return The cutoff, or `0` if none was ever set.
    function retryCutoff(uint256 _originChainId) public view virtual returns (uint120) {
        return _retryCutoffs[_originChainId];
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

    /// @notice Helper function used by `updateExecutor`.
    function _setExecutor(address _executor) internal {
        if (_executor.code.length == 0) revert Errors.HAS_NO_CODE(_executor);

        emit ExecutorUpdated(executor, _executor);

        executor = _executor;
    }

    /// @notice Helper function used by `initialize` and
    ///         `updateMinFailedMessageGas`.
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
    uint256[44] private __gap;
}
