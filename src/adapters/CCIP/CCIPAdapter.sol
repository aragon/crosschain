// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import { Errors } from "../../lib/Errors.sol";

import { BaseAdapter } from "../BaseAdapter.sol";
import { IBaseAdapter } from "../IBaseAdapter.sol";

/// @title CCIPAdapter
/// @notice Chainlink CCIP implementation of `IBaseAdapter`.
/// @dev `sendMessage` must be reached by `delegatecall` from the controller, so
///      that the controller pays the fee from its own balance and CCIP
///      attributes the message to the controller rather than to this adapter.
///      `ccipReceive` runs as this adapter under a plain `CALL` from the router.
/// @custom:security-contact sirt@aragon.org
contract CCIPAdapter is IERC165, IAny2EVMMessageReceiver, BaseAdapter {
    using SafeERC20 for IERC20;

    /// @notice The CCIP Router address.
    IRouterClient public immutable CCIP_ROUTER;

    /// @notice The fee token used to pay bridge fees.
    ///         `address(0)` = chain's native currency.
    /// @dev Immutable rather than stored: under `delegatecall` a storage read
    ///      would resolve against the controller's slots. Changing the fee
    ///      token requires deploying a new adapter.
    address public immutable FEE_TOKEN;

    /// @notice Restricts the receive path to the configured CCIP router.
    // forge-lint: disable-next-line(unwrapped-modifier-logic)
    modifier onlyRouter() {
        if (msg.sender != address(CCIP_ROUTER)) {
            revert Errors.CALLER_NOT_CCIP_ROUTER();
        }

        _;
    }

    /// @param _crosschainController The LOCAL controller that owns this adapter.
    /// @param _ccipRouter The CCIP router on this chain.
    /// @param _feeToken The fee token, or `address(0)` for native. A non-native
    ///        token must be a deployed contract.
    /// @param _chainIdRegistry The CCIP chain id <-> selector table.
    /// @param _trustedRemoteConfigs The remote controllers trusted to originate
    ///        messages, per standard chain id.
    constructor(
        address _crosschainController,
        address _ccipRouter,
        address _feeToken,
        address _chainIdRegistry,
        TrustedRemoteConfig[] memory _trustedRemoteConfigs
    )
        BaseAdapter(_crosschainController, _chainIdRegistry, _trustedRemoteConfigs)
    {
        // Also covers `address(0)`, which trivially has no code.
        if (_ccipRouter.code.length == 0) revert Errors.HAS_NO_CODE(_ccipRouter);

        // `address(0)` is the native currency and is always valid.
        // Anything else must be a deployed token contract.
        if (_feeToken != address(0) && _feeToken.code.length == 0) {
            revert Errors.HAS_NO_CODE(_feeToken);
        }

        CCIP_ROUTER = IRouterClient(_ccipRouter);
        FEE_TOKEN = _feeToken;
    }

    /// @inheritdoc IBaseAdapter
    function quoteFee(address _receiver, uint256 _destinationChainId, uint256 _gasLimit, bytes calldata _message)
        public
        view
        virtual
        override
        returns (address, uint256)
    {
        if (_receiver == address(0)) revert Errors.ZERO_ADDRESS();

        // Reverts if not set.
        uint64 nativeChainId = SafeCast.toUint64(toNativeChainId(_destinationChainId));

        return (FEE_TOKEN, CCIP_ROUTER.getFee(nativeChainId, _buildMessage(_receiver, _gasLimit, _message, FEE_TOKEN)));
    }

    /// @inheritdoc IBaseAdapter
    function sendMessage(address _receiver, uint256 _destinationChainId, uint256 _gasLimit, bytes calldata _message)
        public
        payable
        virtual
        override
        onlyDelegatecallFromController
        returns (uint256, uint256)
    {
        if (_receiver == address(0)) revert Errors.ZERO_ADDRESS();

        // Reverts if not set.
        uint64 nativeChainId = SafeCast.toUint64(toNativeChainId(_destinationChainId));

        // A locally configured lane is not proof the bridge still serves it:
        if (!CCIP_ROUTER.isChainSupported(nativeChainId)) {
            revert Errors.DESTINATION_CHAIN_ID_NOT_SUPPORTED(nativeChainId);
        }

        Client.EVM2AnyMessage memory ccipMessage = _buildMessage(_receiver, _gasLimit, _message, FEE_TOKEN);

        // CCIP does not refund overpayment, so quote and pay exactly.
        uint256 fee = CCIP_ROUTER.getFee(nativeChainId, ccipMessage);

        bytes32 messageId;

        // `address(this)` is the CONTROLLER here: it is the fee payer.
        if (FEE_TOKEN == address(0)) {
            uint256 balance = address(this).balance;
            if (balance < fee) {
                revert Errors.INSUFFICIENT_FEE_BALANCE(address(0), fee, balance);
            }

            messageId = CCIP_ROUTER.ccipSend{ value: fee }(nativeChainId, ccipMessage);
        } else {
            // Unreachable from this controller: `forwardMessage` is non-payable,
            // so `msg.value` is always 0 under its `delegatecall`. Kept as a
            // defensive assertion for any other controller that reaches this
            // code with value attached, where the fee is paid in ERC20 and the
            // native value would serve no purpose.
            if (msg.value != 0) revert Errors.UNEXPECTED_NATIVE_VALUE();

            uint256 balance = IERC20(FEE_TOKEN).balanceOf(address(this));
            if (balance < fee) {
                revert Errors.INSUFFICIENT_FEE_BALANCE(FEE_TOKEN, fee, balance);
            }

            // The Router pulls the fee via `transferFrom` from the CONTROLLER,
            // which is the account granting the allowance under `delegatecall`.
            IERC20(FEE_TOKEN).forceApprove(address(CCIP_ROUTER), fee);

            messageId = CCIP_ROUTER.ccipSend(nativeChainId, ccipMessage);

            // Leave no standing allowance on the controller.
            IERC20(FEE_TOKEN).forceApprove(address(CCIP_ROUTER), 0);
        }

        return (uint256(messageId), fee);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) public virtual onlyRouter {
        address srcAddress = abi.decode(message.sender, (address));

        // Transform CCIP's chain selector into the standard chain Id.
        uint256 originChainId = fromNativeChainId(message.sourceChainSelector);

        if (srcAddress == address(0) || _trustedRemotes[originChainId] != srcAddress) {
            revert Errors.REMOTE_NOT_TRUSTED();
        }

        _forwardMessage(uint256(message.messageId), message.data, originChainId);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IBaseAdapter).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @notice Builds the CCIP message. No CCIP token transfer is ever attached
    ///         - `tokenAmounts` is always empty and only the payload travels.
    ///         The ERC20 fee, when configured, is separate: the router pulls it
    ///         from the controller.
    function _buildMessage(address _receiver, uint256 _gasLimit, bytes memory _message, address _feeToken)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        bytes memory extraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({ gasLimit: _gasLimit, allowOutOfOrderExecution: true })
        );

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: _message,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: extraArgs,
            feeToken: _feeToken
        });
    }
}
