// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { Executor } from "@src/Executor.sol";
import { Executor as CommonsExecutor } from "@aragon/osx-commons-contracts/src/executors/Executor.sol";
import { Errors } from "@src/lib/Errors.sol";
import { TransactionState } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@mocks/ERC20Mock.sol";
import { SilentFailERC20 } from "@mocks/SilentFailERC20.sol";
import { NoReturnDataERC20 } from "@mocks/NoReturnDataERC20.sol";
import { FeeOnTransferERC20 } from "@mocks/FeeOnTransferERC20.sol";
import { TokenPuller } from "@mocks/TokenPuller.sol";

/// @title CrossChainControllerErc20BearingActionsTest
/// @notice The ERC20 counterpart to `valueBearingActions.t.sol`: how an inbound
///         message that moves TOKENS behaves.
///
/// @dev An ERC20 action is just `Action{to: token, value: 0, data: transfer(..)}`,
///      so the same rule holds -- the message carries instructions, and the
///      tokens must already sit on the executor. Two things differ from native
///      value and are what these tests are really for:
///
///      1. Receiving tokens needs no code support. Native pre-funding needs
///         `Executor.receive()`; an ERC20 balance just appears via the token's
///         own ledger, so ANY executor address can hold tokens.
///      2. Failure is not guaranteed to be loud. `Executor` runs each action
///         with a raw `.call` and branches only on the call's `success` flag --
///         it never inspects returndata. A token that returns `false` instead
///         of reverting is therefore recorded as a SUCCESSFUL action, and the
///         message is marked `Executed` with nothing moved. Native value has no
///         equivalent: an underfunded `call{value: x}` always fails loudly.
contract CrossChainControllerErc20BearingActionsTest is CrossChainControllerBase {
    /// @dev A second controller wired to the standalone `Executor`, so the
    ///      executor's token balance is distinct from the DAO's.
    CrossChainController internal execController;
    Executor internal standaloneExecutor;

    ERC20Mock internal token;
    SilentFailERC20 internal silentToken;
    NoReturnDataERC20 internal noReturnToken;
    FeeOnTransferERC20 internal fotToken;
    TokenPuller internal puller;

    address internal tokenRecipient;

    function setUp() public virtual override {
        super.setUp();

        token = new ERC20Mock("Payload", "PAY");
        silentToken = new SilentFailERC20();
        noReturnToken = new NoReturnDataERC20();
        fotToken = new FeeOnTransferERC20();
        puller = new TokenPuller();
        tokenRecipient = makeAddr("tokenRecipient");

        standaloneExecutor = new Executor();
        execController = deployController(address(daoMock), address(standaloneExecutor));
        standaloneExecutor.transferOwnership(address(execController));

        daoMock.setHasPermission(address(execController), alice, manageConfigPermissionId, true);
        daoMock.setHasPermission(address(execController), alice, retryMessagePermissionId, true);
        daoMock.setHasPermission(address(execController), alice, cancelMessagePermissionId, true);

        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        _configureLaneOn(execController, CHAIN_ID, address(adapterA), remoteAdapterA);
    }

    // -------------------------------------------------------------------------
    // Helpers.
    // -------------------------------------------------------------------------

    function _configureLaneOn(CrossChainController _controller, uint256 _chainId, address _local, address _remote)
        internal
    {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = _chainId;
        CrossChainController.ChainConfig[] memory configs = new CrossChainController.ChainConfig[](1);
        configs[0] = _lane(_local, _remote);

        vm.prank(alice);
        _controller.updateConfig(chainIds, configs);
    }

    /// @dev The canonical ERC20 payout action: zero native value, the transfer
    ///      encoded as calldata against the token.
    function _transferAction(address _token, address _to, uint256 _amount)
        internal
        pure
        returns (Action[] memory actions)
    {
        actions = new Action[](1);
        actions[0] = Action({ to: _token, value: 0, data: abi.encodeCall(IERC20.transfer, (_to, _amount)) });
    }

    function _deliver(CrossChainController _controller, uint256 _nonce, Action[] memory _actions)
        internal
        returns (bytes memory encodedTx, bytes32 txId)
    {
        bytes memory message = abi.encode(_actions);
        encodedTx = _encodedTx(_nonce, CHAIN_ID, message);
        txId = _txId(_nonce, CHAIN_ID, message);

        vm.prank(address(adapterA));
        _controller.receiveMessage(_nonce, encodedTx, CHAIN_ID);
    }

    // -------------------------------------------------------------------------
    // Where the tokens come from.
    // -------------------------------------------------------------------------

    /// @dev The ERC20 mirror of the native headline test: the transfer is paid
    ///      out of the EXECUTOR's token balance, and the controller's own
    ///      holdings (its ERC20 bridge-fee float) are not spendable by an
    ///      inbound action.
    function test_tokensArePaidFromExecutorBalanceAndControllerFloatIsUntouched() public {
        token.setBalance(address(standaloneExecutor), 100 ether);
        feeToken.setBalance(address(execController), 50 ether);

        (, bytes32 txId) = _deliver(execController, 1, _transferAction(address(token), tokenRecipient, 100 ether));

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(token.balanceOf(tokenRecipient), 100 ether, "recipient is paid from the executor");
        assertEq(token.balanceOf(address(standaloneExecutor)), 0);
        assertEq(
            feeToken.balanceOf(address(execController)),
            50 ether,
            "the controller's ERC20 fee float must not be spendable by actions"
        );
    }

    /// @dev On the `executor == dao` wiring the tokens come from the DAO.
    function test_daoExecutorPaysTokensFromDaoBalance() public {
        token.setBalance(address(daoMock), 100 ether);

        (, bytes32 txId) = _deliver(controller, 1, _transferAction(address(token), tokenRecipient, 100 ether));

        assertEq(uint256(controller.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(token.balanceOf(tokenRecipient), 100 ether);
        assertEq(token.balanceOf(address(daoMock)), 0);
    }

    /// @dev Unlike native pre-funding, holding ERC20 needs no `receive()` and
    ///      no cooperation from the executor at all -- the balance lives on the
    ///      token's ledger. Pinned because it is the reason the ERC20 story
    ///      needs no contract change to support.
    function test_executorHoldsTokensWithoutAnyCodeSupport() public {
        address fundedBySomeoneElse = makeAddr("someoneElse");
        token.setBalance(fundedBySomeoneElse, 10 ether);

        vm.prank(fundedBySomeoneElse);
        token.transfer(address(standaloneExecutor), 10 ether);

        assertEq(token.balanceOf(address(standaloneExecutor)), 10 ether, "a plain transfer funds the executor");

        _deliver(execController, 1, _transferAction(address(token), tokenRecipient, 10 ether));
        assertEq(token.balanceOf(tokenRecipient), 10 ether);
    }

    /// @dev The two-action pattern real integrations use: approve, then let a
    ///      third party pull. Both actions run under the executor's identity,
    ///      so the allowance is the executor's.
    function test_approveThenThirdPartyPullWorksInOneMessage() public {
        token.setBalance(address(standaloneExecutor), 40 ether);

        Action[] memory actions = new Action[](2);
        actions[0] =
            Action({ to: address(token), value: 0, data: abi.encodeCall(IERC20.approve, (address(puller), 40 ether)) });
        actions[1] = Action({
            to: address(puller), value: 0, data: abi.encodeCall(TokenPuller.pull, (address(token), 40 ether))
        });

        (, bytes32 txId) = _deliver(execController, 1, actions);

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(puller.pulled(), 40 ether);
        assertEq(token.balanceOf(address(puller)), 40 ether);
        assertEq(token.balanceOf(address(standaloneExecutor)), 0);
    }

    // -------------------------------------------------------------------------
    // Underfunded, with a REVERTING token: same recovery loop as native.
    // -------------------------------------------------------------------------

    /// @dev A standard (OpenZeppelin) token reverts when short, so the batch
    ///      reverts, the delivery is captured as `Delivered`, and a retry after
    ///      funding pays out -- identical to the native-value recovery loop.
    function test_underfundedTransferIsCapturedAsDeliveredThenPaidOnRetry() public {
        (bytes memory encodedTx, bytes32 txId) =
            _deliver(execController, 1, _transferAction(address(token), tokenRecipient, 100 ether));

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Delivered));
        assertEq(token.balanceOf(tokenRecipient), 0);
        assertGt(execController.getTransaction(txId).bridgedAt, 0);

        token.setBalance(address(standaloneExecutor), 100 ether);

        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(token.balanceOf(tokenRecipient), 100 ether);
    }

    function test_underfundedTransferSurfacesActionFailedReason() public {
        bytes memory message = abi.encode(_transferAction(address(token), tokenRecipient, 100 ether));
        bytes memory encodedTx = _encodedTx(9, CHAIN_ID, message);
        bytes32 expectedTxId = _txId(9, CHAIN_ID, message);
        bytes memory expectedReason = abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0));

        vm.expectEmit(true, true, true, true, address(execController));
        emit MessageExecutionFailed(CHAIN_ID, 9, expectedTxId, encodedTx, expectedReason);

        vm.prank(address(adapterA));
        execController.receiveMessage(9, encodedTx, CHAIN_ID);
    }

    function test_retryOfStillUnderfundedTransferRevertsAndKeepsItRetryable() public {
        (bytes memory encodedTx, bytes32 txId) =
            _deliver(execController, 1, _transferAction(address(token), tokenRecipient, 100 ether));

        token.setBalance(address(standaloneExecutor), 100 ether - 1);

        vm.expectRevert(abi.encodeWithSelector(CommonsExecutor.ActionFailed.selector, uint256(0)));
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Delivered));

        token.setBalance(address(standaloneExecutor), 100 ether);
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(token.balanceOf(tokenRecipient), 100 ether);
    }

    function test_unfundableTokenMessageCanBeCancelled() public {
        (bytes memory encodedTx, bytes32 txId) =
            _deliver(execController, 1, _transferAction(address(token), tokenRecipient, 100 ether));

        vm.prank(alice);
        execController.cancelMessage(encodedTx);

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Cancelled));

        token.setBalance(address(standaloneExecutor), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        assertEq(token.balanceOf(tokenRecipient), 0);
    }

    /// @dev `allowFailureMap` is 0, so a batch that runs out of tokens midway
    ///      is rolled back whole -- the first payout does not stick.
    function test_partiallyFundedTokenBatchIsRolledBackWhole() public {
        token.setBalance(address(standaloneExecutor), 100 ether);

        address secondRecipient = makeAddr("secondRecipient");
        Action[] memory actions = new Action[](2);
        actions[0] = Action({
            to: address(token), value: 0, data: abi.encodeCall(IERC20.transfer, (tokenRecipient, 100 ether))
        });
        actions[1] = Action({
            to: address(token), value: 0, data: abi.encodeCall(IERC20.transfer, (secondRecipient, 100 ether))
        });

        (, bytes32 txId) = _deliver(execController, 1, actions);

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Delivered));
        assertEq(token.balanceOf(tokenRecipient), 0, "the funded first payout must roll back with the batch");
        assertEq(token.balanceOf(secondRecipient), 0);
        assertEq(token.balanceOf(address(standaloneExecutor)), 100 ether, "the executor keeps every token");
    }

    // -------------------------------------------------------------------------
    // The gap: tokens that fail QUIETLY.
    // -------------------------------------------------------------------------

    /// @dev `Executor` branches only on the low-level call's `success` flag and
    ///      never inspects returndata, so a token that returns `false` instead
    ///      of reverting is treated as a successful action. The message is
    ///      recorded `Executed` even though NOTHING moved.
    ///
    ///      This has no native-value equivalent: `call{value: x}` with too
    ///      little balance always fails loudly. It is inherited from the
    ///      commons `Executor` (a DAO proposal behaves the same way), but the
    ///      cross-chain consequence is sharper -- see the companion test for
    ///      why the usual recovery does not apply.
    function test_silentFailTokenIsRecordedAsExecutedThoughNothingMoved() public {
        // Executor holds nothing; `SilentFailERC20.transfer` returns false.
        assertEq(silentToken.balanceOf(address(standaloneExecutor)), 0);

        (, bytes32 txId) = _deliver(execController, 1, _transferAction(address(silentToken), tokenRecipient, 100 ether));

        assertEq(
            uint256(execController.getTransaction(txId).state),
            uint256(TransactionState.Executed),
            "a silent `false` return is indistinguishable from success to the executor"
        );
        assertEq(silentToken.balanceOf(tokenRecipient), 0, "no tokens moved despite the Executed state");
    }

    /// @dev The consequence of the above: `Executed` is terminal. Retry needs
    ///      `Delivered`, redelivery is refused, and cancel needs `Delivered` --
    ///      so once funds arrive there is no way to re-run THIS message. A new
    ///      message from the origin chain is the only recovery.
    function test_silentFailTokenMessageIsUnrecoverableAfterwards() public {
        (bytes memory encodedTx, bytes32 txId) =
            _deliver(execController, 1, _transferAction(address(silentToken), tokenRecipient, 100 ether));

        // The tokens show up afterwards -- too late.
        silentToken.setBalance(address(standaloneExecutor), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        execController.retryMessage(encodedTx);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        execController.cancelMessage(encodedTx);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_DELIVERED_OR_EXECUTED.selector, txId));
        vm.prank(address(adapterA));
        execController.receiveMessage(1, encodedTx, CHAIN_ID);

        assertEq(silentToken.balanceOf(tokenRecipient), 0, "the payout can never be recovered by this message");
    }

    /// @dev The mitigation lives in the PAYLOAD, not in the messaging layer:
    ///      routing the transfer through a callee that uses `SafeERC20` turns
    ///      the silent failure back into a loud, retryable one.
    function test_silentFailTokenIsCaughtWhenPayloadRoutesThroughSafeErc20() public {
        silentToken.setBalance(address(standaloneExecutor), 0);

        Action[] memory actions = new Action[](2);
        actions[0] = Action({
            to: address(silentToken), value: 0, data: abi.encodeCall(IERC20.approve, (address(puller), 100 ether))
        });
        actions[1] = Action({
            to: address(puller), value: 0, data: abi.encodeCall(TokenPuller.pull, (address(silentToken), 100 ether))
        });

        (, bytes32 txId) = _deliver(execController, 1, actions);

        assertEq(
            uint256(execController.getTransaction(txId).state),
            uint256(TransactionState.Delivered),
            "a SafeERC20 callee turns the silent failure back into a retryable one"
        );
        assertEq(puller.pulled(), 0);
    }

    /// @dev The counterpart, and the reason the mitigation has to be deliberate:
    ///      a merely TYPED `IERC20.transferFrom` does not save the payload.
    ///      Solidity reverts only when returndata cannot be decoded, never on a
    ///      well-encoded `false`, so a naive callee swallows the failure just
    ///      like the executor's raw `.call` and the message is still `Executed`.
    function test_silentFailTokenIsNotCaughtByAMerelyTypedCallee() public {
        silentToken.setBalance(address(standaloneExecutor), 0);

        Action[] memory actions = new Action[](2);
        actions[0] = Action({
            to: address(silentToken), value: 0, data: abi.encodeCall(IERC20.approve, (address(puller), 100 ether))
        });
        actions[1] = Action({
            to: address(puller),
            value: 0,
            data: abi.encodeCall(TokenPuller.pullUnchecked, (address(silentToken), 100 ether))
        });

        (, bytes32 txId) = _deliver(execController, 1, actions);

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(silentToken.balanceOf(address(puller)), 0, "nothing moved");
        assertEq(puller.pulled(), 100 ether, "yet the callee booked the pull as done");
    }

    // -------------------------------------------------------------------------
    // Other non-standard shapes.
    // -------------------------------------------------------------------------

    /// @dev A USDT-style token that returns no data works, because the executor
    ///      calls it with a raw `.call` and ignores returndata. A typed
    ///      `IERC20.transfer` from the executor would have reverted here.
    function test_noReturnDataTokenTransfersSuccessfully() public {
        noReturnToken.setBalance(address(standaloneExecutor), 100e6);

        (, bytes32 txId) = _deliver(execController, 1, _transferAction(address(noReturnToken), tokenRecipient, 100e6));

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(noReturnToken.balanceOf(tokenRecipient), 100e6);
    }

    /// @dev The flip side, and why a payload must not assume every callee
    ///      copes: a merely TYPED `IERC20.transferFrom` reverts against a
    ///      no-return token, because solc cannot decode the missing `bool`.
    ///      Routing the same token through `SafeERC20` succeeds.
    function test_noReturnDataTokenBreaksTypedCalleeButNotSafeErc20() public {
        noReturnToken.setBalance(address(standaloneExecutor), 200e6);

        Action[] memory typedActions = new Action[](2);
        typedActions[0] = Action({
            to: address(noReturnToken), value: 0, data: abi.encodeCall(IERC20.approve, (address(puller), 100e6))
        });
        typedActions[1] = Action({
            to: address(puller),
            value: 0,
            data: abi.encodeCall(TokenPuller.pullUnchecked, (address(noReturnToken), 100e6))
        });

        (, bytes32 typedTxId) = _deliver(execController, 1, typedActions);

        assertEq(
            uint256(execController.getTransaction(typedTxId).state),
            uint256(TransactionState.Delivered),
            "the undecodable empty return reverts the typed call"
        );
        assertEq(puller.pulled(), 0);

        // Same token, same executor -- but through `SafeERC20`.
        Action[] memory safeActions = new Action[](2);
        safeActions[0] = typedActions[0];
        safeActions[1] = Action({
            to: address(puller), value: 0, data: abi.encodeCall(TokenPuller.pull, (address(noReturnToken), 100e6))
        });

        (, bytes32 safeTxId) = _deliver(execController, 2, safeActions);

        assertEq(uint256(execController.getTransaction(safeTxId).state), uint256(TransactionState.Executed));
        assertEq(puller.pulled(), 100e6);
        assertEq(noReturnToken.balanceOf(address(puller)), 100e6);
    }

    /// @dev A fee-on-transfer token delivers less than the encoded amount and
    ///      the batch still succeeds -- the messaging layer neither detects nor
    ///      compensates for the shortfall. A payload-authoring concern.
    function test_feeOnTransferTokenDeliversLessAndStillSucceeds() public {
        fotToken.setBalance(address(standaloneExecutor), 100 ether);

        (, bytes32 txId) = _deliver(execController, 1, _transferAction(address(fotToken), tokenRecipient, 100 ether));

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Executed));
        assertEq(fotToken.balanceOf(tokenRecipient), 90 ether, "10% was taken by the token");
        assertEq(fotToken.balanceOf(address(standaloneExecutor)), 0);
    }

    // -------------------------------------------------------------------------
    // Tokens cannot ride the message either.
    // -------------------------------------------------------------------------

    /// @dev There is no token analogue of `msg.value`: an ERC20 can only move
    ///      by a call the executor itself makes. A message from a lane whose
    ///      executor holds nothing moves nothing, no matter who is funded.
    function test_messageCannotBringTokensFromTheOriginChain() public {
        // Everyone EXCEPT the executor is funded.
        token.setBalance(address(execController), 100 ether);
        token.setBalance(address(daoMock), 100 ether);
        token.setBalance(alice, 100 ether);

        (, bytes32 txId) = _deliver(execController, 1, _transferAction(address(token), tokenRecipient, 100 ether));

        assertEq(uint256(execController.getTransaction(txId).state), uint256(TransactionState.Delivered));
        assertEq(token.balanceOf(tokenRecipient), 0);
        assertEq(token.balanceOf(address(execController)), 100 ether, "the controller's own tokens stay put");
    }
}
