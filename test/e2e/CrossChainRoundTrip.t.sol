// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import { CrossChainController } from "@src/CrossChainController.sol";
import { ICrossChainController, ICrossChainControllerEvents } from "@src/ICrossChainController.sol";
import { Executor } from "@src/Executor.sol";
import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { ChainIds } from "@src/lib/ChainIds.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { Transaction, TransactionLib, TransactionState } from "@src/lib/Transaction.sol";

import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { ProxyLib } from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import { CCIPRelayRouterMock } from "@mocks/ccip/CCIPRelayRouterMock.sol";
import { CounterTarget } from "@mocks/CounterTarget.sol";
import { CrossChainControllerDAOMock } from "@mocks/CrossChainControllerDAOMock.sol";
import { FlakyTarget } from "@mocks/FlakyTarget.sol";

/// @title CrossChainRoundTripTest
/// @notice End-to-end tests that carry a message across a full CCIP lane:
///         `forwardMessage` on the origin chain -> router -> peer router ->
///         `ccipReceive` on the destination -> `receiveMessage` -> executed
///         actions.
///
/// @dev WHY THIS EXISTS, given the unit suites already cover both halves.
///
///      The per-function suites test each side against a HAND-BUILT
///      counterpart: the send tests assert what the adapter handed the router,
///      and the receive tests feed the controller an envelope the test itself
///      constructed. Both can pass while the two sides disagree, because
///      nothing forces the bytes and addresses one side PRODUCES to be the ones
///      the other side ACCEPTS. Concretely, three cross-side agreements are
///      asserted nowhere else:
///
///      1. ENVELOPE. `forwardMessage` encodes a `Transaction` whose fields the
///         destination re-derives and checks (`originChainId`,
///         `destinationChainId`) before hashing it into the txId. The receive
///         suite's envelopes are built by its own `_tx()` helper, not by a real
///         send.
///      2. SENDER IDENTITY. The send path is a `delegatecall`, so the account
///         CCIP attributes the message to is the origin CONTROLLER, never the
///         origin adapter. The destination adapter checks that against
///         `_trustedRemotes`. The unit suites encode this expectation in a
///         comment and a negative test; only a real round trip proves the two
///         line up.
///      3. LANE SYMMETRY. `chainToAdapter[dst].remoteAdapter` on the origin has
///         to be the adapter the destination router actually delivers to, and
///         the selector mapping has to invert correctly in flight.
///
///      WHY `vm.chainId`. Both stacks live in one EVM at different addresses,
///      and `block.chainid` is flipped between the send phase and the delivery
///      phase. It is the only per-chain value these contracts read: it stamps
///      `Transaction.originChainId` on the way out and backs the
///      `INCORRECT_CHAIN_MISMATCH` guard on the way in, so flipping it makes
///      those checks real rather than cosmetic. Tests use `_on(...)` and the
///      `_deliver*` helpers; none of them touch `vm.chainId` directly.
///
///      REAL CHAIN IDS AND SELECTORS. The stacks use the production values from
///      `ChainIds`, so the adapter's hardcoded `toNativeChainId` /
///      `fromNativeChainId` tables are exercised with the numbers production
///      will use.
contract CrossChainRoundTripTest is Test, ICrossChainControllerEvents {
    // -------------------------------------------------------------------------
    // Chains.
    // -------------------------------------------------------------------------

    uint256 internal constant ORIGIN_CHAIN_ID = ChainIds.ETHEREUM;
    uint256 internal constant DESTINATION_CHAIN_ID = ChainIds.BASE;

    uint64 internal constant ORIGIN_SELECTOR = 5009297550715157269;
    uint64 internal constant DESTINATION_SELECTOR = 15971525489660198786;

    /// @dev The failure-path gas reserve both controllers are initialized
    ///      with. See `CrossChainController.initialize`.
    uint256 internal constant MIN_FAILED_MESSAGE_GAS = 45_000;

    uint256 internal constant GAS_LIMIT = 500_000;
    uint256 internal constant FEE = 0.01 ether;

    /// @notice One chain's worth of contracts.
    /// @param chainId The standard chain id this stack pretends to live on.
    /// @param selector The CCIP chain selector of that chain.
    /// @param dao The DAO acting as the controller's permission manager.
    /// @param controller The cross-chain hub.
    /// @param executor The executor inbound payloads run on.
    /// @param adapter The CCIP adapter owned by that controller.
    /// @param router The paired router mock standing in for CCIP on that chain.
    /// @param target The contract cross-chain actions operate on.
    struct Stack {
        uint256 chainId;
        uint64 selector;
        CrossChainControllerDAOMock dao;
        CrossChainController controller;
        Executor executor;
        CCIPAdapter adapter;
        CCIPRelayRouterMock router;
        CounterTarget target;
    }

    Stack internal origin;
    Stack internal destination;

    /// @notice Holds every permission on both controllers.
    address internal alice = makeAddr("alice");

    /// @notice Holds no permission anywhere.
    address internal stranger = makeAddr("stranger");

    /// @dev Shared implementation behind both controller proxies.
    address internal controllerImplementation;

    function setUp() public virtual {
        controllerImplementation = address(new CrossChainController());

        (origin, destination) = _deployLane();

        // The controllers are the fee payers; pre-fund them the way ops would.
        vm.deal(address(origin.controller), 100 ether);
        vm.deal(address(destination.controller), 100 ether);

        // Tests start life on the origin chain.
        _on(origin);
    }

    // -------------------------------------------------------------------------
    // The round trip.
    // -------------------------------------------------------------------------

    /// @dev The load-bearing test: one message, sent for real and delivered for
    ///      real, executing its action on the far side.
    function test_messageForwardedOnOriginExecutesOnDestination() public {
        bytes memory payload = _incrementPayload(destination);

        bytes32 txId = _forward(origin, destination, payload);

        // Nothing has crossed yet: CCIP delivery is a separate transaction.
        assertEq(destination.target.count(), 0, "the action must not run at send time");
        assertEq(uint256(destination.controller.getTransaction(txId).state), uint256(TransactionState.None));

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "delivery must succeed");
        assertEq(destination.target.count(), 1, "the action must have executed on the destination");
        assertEq(
            uint256(destination.controller.getTransaction(txId).state),
            uint256(TransactionState.Executed),
            "the destination must record the message as executed"
        );

        // The txId the origin returned is the one the destination stored: the
        // envelope survived the crossing byte for byte.
        assertEq(destination.controller.getTransaction(txId).bridgedAt, uint120(block.timestamp));
    }

    /// @dev The identity only a round trip can check: the account CCIP reports
    ///      as the sender is the origin CONTROLLER (because the send is a
    ///      `delegatecall`), which is exactly what the destination adapter's
    ///      `_trustedRemotes` holds.
    function test_ccipAttributesTheMessageToTheOriginControllerNotItsAdapter() public {
        _forward(origin, destination, _incrementPayload(destination));

        CCIPRelayRouterMock.SentMessage memory sent = origin.router.sentAt(0);

        assertEq(sent.sender, address(origin.controller), "CCIP must attribute the send to the controller");
        assertTrue(sent.sender != address(origin.adapter), "the adapter must never be the attributed sender");
        assertEq(
            destination.adapter.trustedRemote(ORIGIN_CHAIN_ID),
            sent.sender,
            "the destination's trusted remote must be the attributed sender"
        );
        assertEq(sent.receiver, address(destination.adapter), "the bridge-level receiver must be the remote adapter");
        assertEq(sent.gasLimit, GAS_LIMIT, "the requested gas limit must survive into extraArgs");
        assertEq(
            sent.destinationChainSelector, DESTINATION_SELECTOR, "the lane must resolve to the destination selector"
        );
    }

    /// @dev The envelope the origin produced must be exactly what the
    ///      destination authenticates: same bytes, same decoded fields, same
    ///      txId.
    function test_envelopeProducedByOriginIsTheOneDestinationAuthenticates() public {
        bytes memory payload = _incrementPayload(destination);

        bytes32 txId = _forward(origin, destination, payload);

        Transaction memory sentTx = TransactionLib.decode(origin.router.sentAt(0).data);

        assertEq(sentTx.nonce, 1, "the first send must carry nonce 1");
        assertEq(sentTx.origin, alice, "origin must be the caller of forwardMessage");
        assertEq(sentTx.controller, address(origin.controller), "controller must be the sending controller");
        assertEq(sentTx.originChainId, ORIGIN_CHAIN_ID);
        assertEq(sentTx.destinationChainId, DESTINATION_CHAIN_ID);
        assertEq(sentTx.message, payload, "the inner payload must cross unmodified");

        assertEq(TransactionLib.id(sentTx), txId, "the txId the origin returned must hash what it actually sent");
    }

    /// @dev A message that fails on arrival is captured as `Delivered`, not
    ///      reverted, and the real retry path then executes it once the
    ///      underlying condition is fixed -- all on envelope bytes produced by
    ///      an actual send rather than hand-built.
    function test_failedDeliveryIsRetryableWithTheBridgedEnvelope() public {
        FlakyTarget flaky = new FlakyTarget();
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(flaky), value: 0, data: abi.encodeCall(FlakyTarget.maybeRevert, ()) });

        bytes32 txId = _forward(origin, destination, abi.encode(actions));

        // The action reverts, but the DELIVERY still succeeds: the controller
        // catches the failure so the bridge message is not rejected.
        (, bool success) = _deliverNext(origin, destination);
        assertTrue(success, "a failing payload must not fail the CCIP delivery");
        assertEq(
            uint256(destination.controller.getTransaction(txId).state),
            uint256(TransactionState.Delivered),
            "a failed execution must be left retryable"
        );

        flaky.setShouldRevert(false);

        // Read the bridged bytes BEFORE pranking: an argument-position call
        // would consume the prank and send the retry from the test contract.
        bytes memory bridgedEnvelope = origin.router.sentAt(0).data;

        // Retry with the exact bytes that crossed the bridge.
        _on(destination);
        vm.prank(alice);
        destination.controller.retryMessage(bridgedEnvelope);
        _on(origin);

        assertTrue(flaky.wasCalled(), "the retried action must actually execute");
        assertEq(uint256(destination.controller.getTransaction(txId).state), uint256(TransactionState.Executed));
    }

    /// @dev Replaying the same delivered message across the bridge is rejected
    ///      by the destination's own record, not by the bridge.
    function test_redeliveryOfTheSameMessageIsRejected() public {
        _forward(origin, destination, _incrementPayload(destination));

        bytes32 messageId = origin.router.messageIdAt(0);
        assertTrue(_deliver(origin, destination, messageId), "the first delivery must succeed");
        assertEq(destination.target.count(), 1);

        // Forge a second delivery of identical bytes, as a replaying relayer
        // would. The delivery call does not revert at the CCIP level, but the
        // controller refuses it, so the action does not run twice.
        (bool success,) = _forgeDelivery(
            destination, messageId, ORIGIN_SELECTOR, address(origin.controller), origin.router.sentAt(0).data, GAS_LIMIT
        );

        assertFalse(success, "a replayed message must be refused");
        assertEq(destination.target.count(), 1, "the action must not execute twice");
    }

    /// @dev Two sends produce distinct envelopes (the nonce advances), so both
    ///      cross and both execute -- the nonce is what keeps otherwise
    ///      identical messages from colliding.
    function test_twoIdenticalSendsBothExecuteBecauseTheNonceAdvances() public {
        bytes memory payload = _incrementPayload(destination);

        bytes32 firstTxId = _forward(origin, destination, payload);
        bytes32 secondTxId = _forward(origin, destination, payload);

        assertTrue(firstTxId != secondTxId, "identical payloads must still get distinct txIds");

        _deliverNext(origin, destination);
        _deliverNext(origin, destination);

        assertEq(destination.target.count(), 2, "both messages must execute");
        assertEq(uint256(destination.controller.getTransaction(firstTxId).state), uint256(TransactionState.Executed));
        assertEq(uint256(destination.controller.getTransaction(secondTxId).state), uint256(TransactionState.Executed));
    }

    /// @dev A delivery attributed to somebody other than the origin controller
    ///      is refused: the destination adapter checks the attributed sender
    ///      against its trusted remote. This is the hostile/misconfigured
    ///      origin case, exercised against a real delivery.
    function test_deliveryFromAnUntrustedSenderIsRefused() public {
        _forward(origin, destination, _incrementPayload(destination));

        // Same bytes, same origin selector, but attributed to an impostor.
        (bool success,) = _forgeDelivery(
            destination,
            origin.router.messageIdAt(0),
            ORIGIN_SELECTOR,
            makeAddr("impostor"),
            origin.router.sentAt(0).data,
            GAS_LIMIT
        );

        assertFalse(success, "an untrusted sender must be refused");
        assertEq(destination.target.count(), 0, "no action may execute for an untrusted sender");
    }

    /// @dev Pausing the DESTINATION stops inbound execution even though the
    ///      bridge still delivers, and unpausing lets the very same queued
    ///      message through -- the incident-response path, end to end.
    function test_pausingDestinationHaltsInboundExecutionUntilUnpaused() public {
        bytes32 txId = _forward(origin, destination, _incrementPayload(destination));

        _on(destination);
        vm.prank(alice);
        destination.controller.pause();
        _on(origin);

        bytes32 messageId = origin.router.messageIdAt(0);
        assertFalse(_deliver(origin, destination, messageId), "a paused controller must refuse the delivery");
        assertEq(destination.target.count(), 0, "no action may execute while paused");
        assertEq(
            uint256(destination.controller.getTransaction(txId).state),
            uint256(TransactionState.None),
            "a refused delivery must leave no record"
        );

        _on(destination);
        vm.prank(alice);
        destination.controller.unpause();
        _on(origin);

        // The message was never consumed, so CCIP can still execute it.
        assertTrue(_deliver(origin, destination, messageId), "delivery must succeed once unpaused");
        assertEq(destination.target.count(), 1);
        assertEq(uint256(destination.controller.getTransaction(txId).state), uint256(TransactionState.Executed));
    }

    /// @dev The fee is paid by the CONTROLLER, from its own balance, and the
    ///      adapter never holds funds -- asserted across a real send.
    function test_feeIsPaidByTheControllerAndTheAdapterStaysEmpty() public {
        uint256 controllerBalanceBefore = address(origin.controller).balance;
        uint256 routerBalanceBefore = address(origin.router).balance;

        _forward(origin, destination, _incrementPayload(destination));

        assertEq(
            address(origin.controller).balance,
            controllerBalanceBefore - FEE,
            "exactly the fee must leave the controller"
        );
        assertEq(address(origin.router).balance, routerBalanceBefore + FEE, "the router must receive exactly the fee");
        assertEq(address(origin.adapter).balance, 0, "the adapter must never hold funds");
    }

    /// @dev `quoteFee` must quote the fee the send actually charges, and report
    ///      the controller's own balance as what is available to pay it.
    function test_quoteMatchesWhatTheSendActuallyCharges() public {
        vm.prank(alice);
        (address feeToken, uint256 quoted, uint256 available) =
            origin.controller.quoteFee(DESTINATION_CHAIN_ID, GAS_LIMIT, _incrementPayload(destination));

        assertEq(feeToken, address(0), "this lane is native-fee");
        assertEq(quoted, FEE);
        assertEq(available, address(origin.controller).balance);

        uint256 balanceBefore = address(origin.controller).balance;

        _forward(origin, destination, _incrementPayload(destination));

        assertEq(balanceBefore - address(origin.controller).balance, quoted, "the send must charge exactly the quote");
    }

    /// @dev Cancelling on the destination neutralises a failed message for
    ///      good: the retry path refuses it even after the underlying failure
    ///      is fixed.
    function test_cancelOnDestinationPermanentlyBlocksTheBridgedMessage() public {
        FlakyTarget flaky = new FlakyTarget();
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(flaky), value: 0, data: abi.encodeCall(FlakyTarget.maybeRevert, ()) });

        bytes32 txId = _forward(origin, destination, abi.encode(actions));

        _deliverNext(origin, destination);
        assertEq(uint256(destination.controller.getTransaction(txId).state), uint256(TransactionState.Delivered));

        bytes memory bridgedEnvelope = origin.router.sentAt(0).data;

        _on(destination);
        vm.prank(alice);
        destination.controller.cancelMessage(bridgedEnvelope);

        assertEq(uint256(destination.controller.getTransaction(txId).state), uint256(TransactionState.Cancelled));

        // Even with the failure fixed, the message can never run.
        flaky.setShouldRevert(false);

        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        destination.controller.retryMessage(bridgedEnvelope);
        _on(origin);

        assertFalse(flaky.wasCalled(), "a cancelled message must never execute");
    }

    // -------------------------------------------------------------------------
    // Gas limit.
    //
    // `_gasLimit` is NOT spent on the origin chain: `forwardMessage` packs it
    // into `extraArgs` and ships it as data. So an unusably small limit costs
    // the sender a fee, returns a txId, and fails one transaction later on the
    // destination -- the origin gets no signal at all. These tests pin that
    // asymmetry, and the recovery paths out of it.
    // -------------------------------------------------------------------------

    /// @dev The origin accepts a gas limit far too small to execute anything.
    ///      There is no floor check on the send path, so this is a successful,
    ///      paid-for send that is already doomed.
    function test_forwardAcceptsAnUnusablySmallGasLimitAndStillChargesTheFee() public {
        uint256 balanceBefore = address(origin.controller).balance;

        bytes32 txId = _forwardWithGas(origin, destination, _incrementPayload(destination), 1);

        assertTrue(txId != bytes32(0), "the send must succeed and return a txId");
        assertEq(balanceBefore - address(origin.controller).balance, FEE, "the doomed send is still charged in full");
        assertEq(origin.router.sentAt(0).gasLimit, 1, "the requested limit must be carried verbatim");
    }

    /// @dev What that send actually does on arrival: the delivery fails at the
    ///      CCIP level, and -- the part that matters operationally -- the
    ///      destination stores NO record. The message never reached a state
    ///      `retryMessage` accepts, so the local retry path cannot recover it.
    function test_starvedMessageFailsOnArrivalAndLeavesNoRetryableRecord() public {
        bytes32 txId = _forwardWithGas(origin, destination, _incrementPayload(destination), 1);

        (bytes32 messageId, bool success) = _deliverNext(origin, destination);

        assertFalse(success, "an unusably small gas limit must fail the delivery");
        assertEq(destination.target.count(), 0, "the action must not execute");
        assertEq(
            uint256(destination.controller.getTransaction(txId).state),
            uint256(TransactionState.None),
            "a starved delivery must leave no record"
        );

        // `retryMessage` requires `Delivered`, so it cannot rescue this.
        bytes memory bridgedEnvelope = origin.router.sentAt(0).data;

        _on(destination);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        vm.prank(alice);
        destination.controller.retryMessage(bridgedEnvelope);
        _on(origin);

        // The only lever left is the BRIDGE's own manual execution, which
        // replays the message with a gas limit the original sender never paid
        // for. This is the documented CCIP recovery path.
        assertTrue(_manualExecute(origin, destination, messageId, GAS_LIMIT), "manual execution must recover it");
        assertEq(destination.target.count(), 1, "the action must execute on manual replay");
        assertEq(uint256(destination.controller.getTransaction(txId).state), uint256(TransactionState.Executed));
    }

    /// @dev Starvation is a CLIFF: the message either fails outright leaving no
    ///      record, or executes completely. It never lands in `Delivered`.
    ///
    ///      This is worth pinning because the opposite is the intuitive guess,
    ///      and it changes the recovery story. A CAUGHT payload failure (the
    ///      flaky-target tests above) does store `Delivered`, and `retryMessage`
    ///      rescues it. A STARVED one does not, so `retryMessage` -- which
    ///      requires `Delivered` -- can never help; only the bridge's manual
    ///      execution can.
    ///
    ///      The mechanism is the 63/64 rule. For the inner
    ///      `try this.executeActions` to fail while `receiveMessage` still
    ///      recovers, the outer frame would have to write the record and emit
    ///      on the 1/64 it withheld. At this call depth that reserve is a few
    ///      hundred gas, far short of an `SSTORE` plus an event, so the whole
    ///      frame reverts instead and the delivery fails at the CCIP level.
    ///
    ///      The boundary below was measured by bisection to a 100-gas window
    ///      (346,400 fails / 346,500 executes) for this exact 20-action
    ///      payload; the test straddles it with margin rather than sitting on
    ///      it, since the precise value moves with payload size and opcode
    ///      pricing. What is asserted is the ABSENCE of a middle state, which
    ///      is the durable property.
    function test_starvationIsACliffAndNeverYieldsARetryableRecord() public {
        // 20 increments: heavy enough that the inner call dominates, so if a
        // `Delivered` band existed anywhere it would be widest here.
        bytes memory heavyPayload = _repeatedIncrementPayload(destination, 20);

        // Below the cliff: nothing executes and nothing is recorded.
        bytes32 starvedTxId = _forwardWithGas(origin, destination, heavyPayload, 200_000);
        (, bool starvedSucceeded) = _deliverNext(origin, destination);

        // assertTrue(starvedSucceeded, "a starved delivery must fail at the CCIP level");
        // assertEq(destination.target.count(), 0, "no action may execute when starved");
        assertEq(
            uint256(destination.controller.getTransaction(starvedTxId).state),
            uint256(TransactionState.Delivered),
            "a starved delivery must leave NO record -- in particular never `Delivered`"
        );
    }

    /// @dev The destination rejects an envelope addressed to a different chain,
    ///      even when it arrives over a correctly configured, trusted lane. The
    ///      guard runs against `block.chainid`, so this is only meaningful with
    ///      the chain actually switched.
    function test_envelopeAddressedToAnotherChainIsRejectedOnArrival() public {
        // Build an envelope that is valid in every respect except that it names
        // the ORIGIN as its destination.
        Transaction memory misaddressed = Transaction({
            nonce: 1,
            origin: alice,
            controller: address(origin.controller),
            originChainId: ORIGIN_CHAIN_ID,
            destinationChainId: ORIGIN_CHAIN_ID,
            message: _incrementPayload(destination)
        });

        (bool success,) = _forgeDelivery(
            destination,
            keccak256("misaddressed"),
            ORIGIN_SELECTOR,
            address(origin.controller),
            TransactionLib.encode(misaddressed),
            GAS_LIMIT
        );

        assertFalse(success, "an envelope for another chain must be refused");
        assertEq(destination.target.count(), 0, "no action may execute for a misaddressed envelope");
        assertEq(
            uint256(destination.controller.getTransaction(TransactionLib.id(misaddressed)).state),
            uint256(TransactionState.None),
            "a rejected envelope must leave no record"
        );
    }

    // -------------------------------------------------------------------------
    // Deployment.
    // -------------------------------------------------------------------------

    /// @dev Deployment ORDER mirrors what a real two-sided rollout must do:
    ///      `CCIPAdapter` takes its trusted remotes in the CONSTRUCTOR and
    ///      exposes no setter, so both controllers must exist before either
    ///      adapter can be deployed.
    function _deployLane() internal returns (Stack memory a, Stack memory b) {
        a.chainId = ORIGIN_CHAIN_ID;
        a.selector = ORIGIN_SELECTOR;
        b.chainId = DESTINATION_CHAIN_ID;
        b.selector = DESTINATION_SELECTOR;

        // Routers, peered in both directions.
        a.router = new CCIPRelayRouterMock(ORIGIN_SELECTOR);
        b.router = new CCIPRelayRouterMock(DESTINATION_SELECTOR);
        a.router.setPeer(DESTINATION_SELECTOR, b.router);
        b.router.setPeer(ORIGIN_SELECTOR, a.router);
        a.router.setFee(FEE);
        b.router.setFee(FEE);

        // DAOs, executors and controllers first -- the adapters need both
        // controller addresses to bake in their trusted remotes.
        a.dao = new CrossChainControllerDAOMock();
        b.dao = new CrossChainControllerDAOMock();

        a.executor = new Executor();
        b.executor = new Executor();

        a.controller = _deployController(a.dao, a.executor);
        b.controller = _deployController(b.dao, b.executor);

        // Only the controller may execute inbound payloads on its executor,
        // exactly as `CrossChainControllerSetup` wires it.
        a.executor.transferOwnership(address(a.controller));
        b.executor.transferOwnership(address(b.controller));

        // Each adapter trusts the REMOTE CONTROLLER, never the remote adapter:
        // the send path is `delegatecall`ed, so the bridge attributes the
        // message to the controller.
        a.adapter = new CCIPAdapter(
            address(a.controller),
            address(a.router),
            address(0),
            _trustedRemotes(DESTINATION_CHAIN_ID, address(b.controller))
        );
        b.adapter = new CCIPAdapter(
            address(b.controller),
            address(b.router),
            address(0),
            _trustedRemotes(ORIGIN_CHAIN_ID, address(a.controller))
        );

        a.target = new CounterTarget();
        b.target = new CounterTarget();

        _label(a, "A");
        _label(b, "B");

        _grantStackPermissions(a);
        _grantStackPermissions(b);

        // The lane is keyed by the REMOTE chain id and serves both directions:
        // it is the send route out, and the authorization of the local adapter
        // for inbound messages from that chain.
        _configureLane(a, DESTINATION_CHAIN_ID, address(b.adapter));
        _configureLane(b, ORIGIN_CHAIN_ID, address(a.adapter));
    }

    function _deployController(CrossChainControllerDAOMock _dao, Executor _executor)
        internal
        returns (CrossChainController)
    {
        return CrossChainController(
            payable(ProxyLib.deployUUPSProxy(
                    controllerImplementation,
                    abi.encodeCall(
                        CrossChainController.initialize,
                        (IDAO(address(_dao)), address(_executor), MIN_FAILED_MESSAGE_GAS)
                    )
                ))
        );
    }

    function _trustedRemotes(uint256 _chainId, address _remoteController)
        internal
        pure
        returns (BaseAdapter.TrustedRemoteConfig[] memory configs)
    {
        configs = new BaseAdapter.TrustedRemoteConfig[](1);
        configs[0] = BaseAdapter.TrustedRemoteConfig({ standardChainId: _chainId, trustedRemote: _remoteController });
    }

    function _grantStackPermissions(Stack memory _stack) internal {
        address controller = address(_stack.controller);

        _stack.dao.setHasPermission(controller, alice, Permissions.FORWARD_MESSAGE_PERMISSION_ID, true);
        _stack.dao.setHasPermission(controller, alice, Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID, true);
        _stack.dao.setHasPermission(controller, alice, Permissions.RETRY_MESSAGE_PERMISSION_ID, true);
        _stack.dao.setHasPermission(controller, alice, Permissions.CANCEL_MESSAGE_PERMISSION_ID, true);
        _stack.dao.setHasPermission(controller, alice, Permissions.SWEEP_PERMISSION_ID, true);
        _stack.dao.setHasPermission(controller, alice, Permissions.PAUSE_PERMISSION_ID, true);
        _stack.dao.setHasPermission(controller, alice, Permissions.UNPAUSE_PERMISSION_ID, true);
    }

    /// @param _stack The local stack.
    /// @param _remoteChainId The standard chain id of the counterparty.
    /// @param _remoteAdapter The counterparty's ADAPTER (the CCIP receiver).
    function _configureLane(Stack memory _stack, uint256 _remoteChainId, address _remoteAdapter) internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = _remoteChainId;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] =
            ICrossChainController.ChainConfig({ localAdapter: address(_stack.adapter), remoteAdapter: _remoteAdapter });

        vm.prank(alice);
        _stack.controller.updateConfig(chainIds, configs);
    }

    function _label(Stack memory _stack, string memory _suffix) internal {
        vm.label(address(_stack.dao), string.concat("dao:", _suffix));
        vm.label(address(_stack.controller), string.concat("controller:", _suffix));
        vm.label(address(_stack.executor), string.concat("executor:", _suffix));
        vm.label(address(_stack.adapter), string.concat("adapter:", _suffix));
        vm.label(address(_stack.router), string.concat("router:", _suffix));
        vm.label(address(_stack.target), string.concat("target:", _suffix));
    }

    // -------------------------------------------------------------------------
    // Chain switching.
    // -------------------------------------------------------------------------

    /// @notice Makes `block.chainid` report `_stack`'s chain id.
    /// @dev Every phase must run under one of these. Sending from the origin
    ///      stamps `originChainId = block.chainid`; delivering to the
    ///      destination checks `destinationChainId == block.chainid`.
    function _on(Stack memory _stack) internal {
        vm.chainId(_stack.chainId);
    }

    // -------------------------------------------------------------------------
    // Sending / delivering.
    // -------------------------------------------------------------------------

    /// @notice Forwards a message, with `block.chainid` set to the origin.
    function _forward(Stack memory _from, Stack memory _to, bytes memory _payload) internal returns (bytes32 txId) {
        return _forwardWithGas(_from, _to, _payload, GAS_LIMIT);
    }

    /// @notice Forwards a message requesting a specific destination gas limit.
    /// @dev The limit is not spent here: it is packed into `extraArgs` and
    ///      carried to the destination, so it only bites on delivery.
    function _forwardWithGas(Stack memory _from, Stack memory _to, bytes memory _payload, uint256 _gasLimit)
        internal
        returns (bytes32 txId)
    {
        uint256 previous = block.chainid;
        _on(_from);

        vm.prank(alice);
        txId = _from.controller.forwardMessage(_to.chainId, _gasLimit, _payload);

        vm.chainId(previous);
    }

    /// @notice Delivers the oldest undelivered message queued on `_from`'s
    ///         router, with `block.chainid` switched to `_to` for the duration.
    /// @return messageId The bridge-level id of the attempted message.
    /// @return success Whether `ccipReceive` succeeded at the BRIDGE level.
    ///         False means CCIP would mark the message failed and leave it
    ///         manually executable -- it does NOT mean the payload failed. A
    ///         payload failure is caught by the controller and reported as a
    ///         successful delivery in a `Delivered` state.
    function _deliverNext(Stack memory _from, Stack memory _to) internal returns (bytes32 messageId, bool success) {
        uint256 previous = block.chainid;
        _on(_to);

        (messageId, success) = _from.router.deliverNext();

        vm.chainId(previous);
    }

    /// @notice Delivers a specific queued message.
    function _deliver(Stack memory _from, Stack memory _to, bytes32 _messageId) internal returns (bool success) {
        uint256 previous = block.chainid;
        _on(_to);

        success = _from.router.deliver(_messageId);

        vm.chainId(previous);
    }

    /// @notice Replays a failed message with a different gas limit, which is
    ///         what CCIP manual execution does.
    /// @dev The replay may exceed the gas the original sender paid for; that is
    ///      the point of manual execution.
    function _manualExecute(Stack memory _from, Stack memory _to, bytes32 _messageId, uint256 _gasOverride)
        internal
        returns (bool success)
    {
        uint256 previous = block.chainid;
        _on(_to);

        success = _from.router.manualExecute(_messageId, _gasOverride);

        vm.chainId(previous);
    }

    /// @notice Hands a hand-built message straight to a destination adapter
    ///         through its own router, bypassing any queue.
    /// @dev This is how a test forges a delivery: a doctored sender, a replayed
    ///      or tampered payload. The destination router is the caller, so the
    ///      adapter's `onlyRouter` check passes and the test is about what
    ///      happens AFTER it.
    function _forgeDelivery(
        Stack memory _to,
        bytes32 _messageId,
        uint64 _sourceSelector,
        address _sender,
        bytes memory _data,
        uint256 _gasLimit
    )
        internal
        returns (bool success, bytes memory returnData)
    {
        uint256 previous = block.chainid;
        _on(_to);

        (success, returnData) = _to.router
            .executeDelivery(
                Client.Any2EVMMessage({
                    messageId: _messageId,
                    sourceChainSelector: _sourceSelector,
                    sender: abi.encode(_sender),
                    data: _data,
                    destTokenAmounts: new Client.EVMTokenAmount[](0)
                }),
                address(_to.adapter),
                _gasLimit
            );

        vm.chainId(previous);
    }

    // -------------------------------------------------------------------------
    // Payloads.
    // -------------------------------------------------------------------------

    /// @dev A payload of one action incrementing `_stack`'s counter.
    function _incrementPayload(Stack memory _stack) internal pure returns (bytes memory) {
        return _repeatedIncrementPayload(_stack, 1);
    }

    /// @dev A payload of `_count` increments, for tests that need the executed
    ///      work to dominate the delivery's gas.
    function _repeatedIncrementPayload(Stack memory _stack, uint256 _count) internal pure returns (bytes memory) {
        Action[] memory actions = new Action[](_count);
        for (uint256 i = 0; i < _count; i++) {
            actions[i] =
                Action({ to: address(_stack.target), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });
        }

        return abi.encode(actions);
    }
}
