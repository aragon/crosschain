// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import { DAO } from "@aragon/osx/core/dao/DAO.sol";
import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { ProxyLib } from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import { CrossChainController } from "@src/CrossChainController.sol";
import { ICrossChainController, ICrossChainControllerEvents } from "@src/ICrossChainController.sol";
import { Executor } from "@src/Executor.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { ChainIdRegistry } from "@src/registry/ChainIdRegistry.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { Transaction, TransactionLib, TransactionState } from "@src/lib/Transaction.sol";

import { CCIPRelayRouterMock } from "@mocks/ccip/CCIPRelayRouterMock.sol";
import { ERC20Mock } from "@mocks/ERC20Mock.sol";
import { GuardedTarget } from "@mocks/E2ETargets.sol";

import { ChainsFixture } from "../fixtures/Chains.sol";

/// @title CrossChainE2EBase
/// @notice Two (optionally three) complete cross-chain stacks -- a REAL OSx
///         `DAO`, a `CrossChainController` behind its UUPS proxy, an `Executor`
///         owned by that controller, and a `CCIPAdapter` -- standing up in a
///         single Foundry process and wired to each other through paired
///         `CCIPRelayRouterMock`s.
///
/// @dev WHY A REAL DAO. Every other suite in this repository runs against
///      `CrossChainControllerDAOMock`, whose `hasPermission` is a settable
///      mapping. That proves the controller CALLS the right permission checks,
///      but never that a real `PermissionManager` grant makes them pass, that a
///      revoke makes them fail, or that a real `DAO.execute` can drive the
///      whole outbound path. Everything here goes through `DAO.grant` /
///      `DAO.revoke` / `DAO.execute`.
///
///      WHY A SEPARATE `Executor`. This is the wiring
///      `CrossChainControllerSetup` produces when no executor is supplied: a
///      standalone, owner-gated `Executor` whose owner is the controller.
///      Inbound payloads therefore execute on the executor, NOT on the DAO, and
///      `GuardedTarget.lastCaller` pins that.
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
///      `test/fixtures/chains.json`, seeded into a real `ChainIdRegistry` per
///      stack, so the adapters resolve their lanes with the numbers production
///      will use and through the same registry a real deployment binds.
abstract contract CrossChainE2EBase is ChainsFixture, ICrossChainControllerEvents {
    using TransactionLib for Transaction;

    // -------------------------------------------------------------------------
    // Chains.
    // -------------------------------------------------------------------------

    uint256 internal immutable ORIGIN_CHAIN_ID;
    uint256 internal immutable DESTINATION_CHAIN_ID;
    uint256 internal immutable THIRD_CHAIN_ID;

    uint64 internal immutable ORIGIN_SELECTOR;
    uint64 internal immutable DESTINATION_SELECTOR;
    uint64 internal immutable THIRD_SELECTOR;

    /// @dev A real chain no stack is wired for and no registry is seeded with,
    ///      used to exercise the unconfigured-lane paths. Real rather than
    ///      arbitrary so the numbers stay production-shaped.
    uint256 internal immutable UNCONFIGURED_CHAIN_ID;

    constructor() {
        ORIGIN_CHAIN_ID = chainId("ethereum");
        DESTINATION_CHAIN_ID = chainId("base");
        THIRD_CHAIN_ID = chainId("arbitrumOne");

        ORIGIN_SELECTOR = ccipSelector("ethereum");
        DESTINATION_SELECTOR = ccipSelector("base");
        THIRD_SELECTOR = ccipSelector("arbitrumOne");

        UNCONFIGURED_CHAIN_ID = chainId("polygon");
    }

    /// @dev The failure-path gas reserve both controllers are initialized with.
    ///      See `CrossChainController.initialize`.
    uint256 internal constant MIN_FAILED_MESSAGE_GAS = 45_000;

    uint256 internal constant GAS_LIMIT = 500_000;
    uint256 internal constant FEE = 0.01 ether;

    bytes internal constant DAO_METADATA = hex"0001";
    string internal constant DAO_URI = "https://example.org";

    /// @notice One chain's worth of contracts.
    /// @param chainId The standard chain id this stack pretends to live on.
    /// @param selector The CCIP chain selector of that chain.
    /// @param dao The OSx DAO acting as the controller's permission manager.
    /// @param controller The cross-chain hub.
    /// @param executor The executor inbound payloads run on.
    /// @param registry The chain id table that adapter resolves lanes through.
    /// @param adapter The CCIP adapter owned by that controller.
    /// @param router The paired router mock standing in for CCIP on that chain.
    /// @param target The contract cross-chain actions operate on.
    struct Stack {
        uint256 chainId;
        uint64 selector;
        DAO dao;
        CrossChainController controller;
        Executor executor;
        ChainIdRegistry registry;
        CCIPAdapter adapter;
        CCIPRelayRouterMock router;
        GuardedTarget target;
    }

    Stack internal origin;
    Stack internal destination;

    /// @notice The governance plugin that executes proposals on each DAO.
    address internal plugin = makeAddr("governancePlugin");

    /// @notice The ops account holding `RETRY_MESSAGE_PERMISSION`.
    /// @dev Deliberately NOT the executor and NOT the DAO: `retryMessage` calls
    ///      back into the executor, so a holder that is itself the execution
    ///      target would re-enter `execute` and trip the reentrancy guard on
    ///      every retry. See `Permissions.RETRY_MESSAGE_PERMISSION_ID`.
    address internal ops = makeAddr("ops");

    /// @notice The account holding `PAUSE_PERMISSION` but never `UNPAUSE`.
    address internal guardian = makeAddr("guardian");

    /// @notice An account holding no permission anywhere.
    address internal stranger = makeAddr("stranger");

    /// @notice The ERC20 fee token used by the fee tests. Deployed once and
    ///         shared, since it is only ever read by balance/allowance checks.
    ERC20Mock internal feeToken;

    /// @dev Shared implementation behind every controller proxy.
    address internal controllerImplementation;

    // -------------------------------------------------------------------------
    // Setup.
    // -------------------------------------------------------------------------

    function setUp() public virtual {
        controllerImplementation = address(new CrossChainController());
        feeToken = new ERC20Mock("Fee", "FEE");

        (origin, destination) =
            _deployLane(ORIGIN_CHAIN_ID, ORIGIN_SELECTOR, DESTINATION_CHAIN_ID, DESTINATION_SELECTOR, address(0));

        // The controllers are the fee payers; pre-fund them the way ops would.
        vm.deal(address(origin.controller), 100 ether);
        vm.deal(address(destination.controller), 100 ether);

        // Tests start life on the origin chain.
        _on(origin);
    }

    /// @notice Deploys a THIRD stack, reachable from the origin.
    /// @dev One-directional on purpose: the origin can send to it, and it
    ///      trusts the origin controller, but the origin adapter does not trust
    ///      it back (trusted remotes are constructor-only). That is all the
    ///      multi-lane and cross-chain-replay scenarios need, and keeping it
    ///      one-directional makes the asymmetry explicit.
    function _deployThirdStack() internal returns (Stack memory c) {
        c.chainId = THIRD_CHAIN_ID;
        c.selector = THIRD_SELECTOR;

        c.router = new CCIPRelayRouterMock(THIRD_SELECTOR);
        c.router.setFee(FEE);
        origin.router.setPeer(THIRD_SELECTOR, c.router);
        c.router.setPeer(ORIGIN_SELECTOR, origin.router);

        c.dao = _deployDao("dao:C");
        c.executor = new Executor();
        c.controller = _deployController(c.dao, c.executor);
        c.executor.transferOwnership(address(c.controller));

        // The registry before the adapter: the binding is constructor-only.
        // C only ever talks to the origin, so that is the one lane it resolves.
        c.registry = _deployRegistry(c.dao);
        c.registry.setChainIdPair(ORIGIN_CHAIN_ID, ORIGIN_SELECTOR);

        c.adapter = new CCIPAdapter(
            address(c.controller),
            address(c.router),
            address(0),
            address(c.registry),
            _trustedRemotes(ORIGIN_CHAIN_ID, address(origin.controller))
        );

        // The origin gains the lane back, on ITS OWN registry.
        origin.registry.setChainIdPair(THIRD_CHAIN_ID, THIRD_SELECTOR);
        c.target = new GuardedTarget();

        _label(c, "C");
        _grantStackPermissions(c);

        _configureLane(c, ORIGIN_CHAIN_ID, address(origin.adapter));
        _configureLane(origin, THIRD_CHAIN_ID, address(c.adapter));

        vm.deal(address(c.controller), 100 ether);
    }

    /// @notice Deploys and fully wires two stacks that can talk to each other.
    /// @dev Deployment ORDER matters and mirrors what a real two-sided rollout
    ///      has to do: `CCIPAdapter` takes its trusted remotes in the
    ///      CONSTRUCTOR and exposes no setter, so both controllers must exist
    ///      before either adapter can be deployed.
    /// @param _aChainId The standard chain id of side A.
    /// @param _aSelector The CCIP selector of side A.
    /// @param _bChainId The standard chain id of side B.
    /// @param _bSelector The CCIP selector of side B.
    /// @param _feeToken The fee token for both sides; `address(0)` for native.
    function _deployLane(uint256 _aChainId, uint64 _aSelector, uint256 _bChainId, uint64 _bSelector, address _feeToken)
        internal
        returns (Stack memory a, Stack memory b)
    {
        a.chainId = _aChainId;
        a.selector = _aSelector;
        b.chainId = _bChainId;
        b.selector = _bSelector;

        // Routers, peered in both directions.
        a.router = new CCIPRelayRouterMock(_aSelector);
        b.router = new CCIPRelayRouterMock(_bSelector);
        a.router.setPeer(_bSelector, b.router);
        b.router.setPeer(_aSelector, a.router);
        a.router.setFee(FEE);
        b.router.setFee(FEE);

        // DAOs, executors and controllers first -- the adapters need both
        // controller addresses to bake in their trusted remotes.
        a.dao = _deployDao("dao:A");
        b.dao = _deployDao("dao:B");

        a.executor = new Executor();
        b.executor = new Executor();

        a.controller = _deployController(a.dao, a.executor);
        b.controller = _deployController(b.dao, b.executor);

        // Only the controller may execute inbound payloads on its executor,
        // exactly as `CrossChainControllerSetup` wires it.
        a.executor.transferOwnership(address(a.controller));
        b.executor.transferOwnership(address(b.controller));

        // One registry per chain, seeded with the lane that chain has to
        // resolve -- the remote one, in both directions. Deployed before the
        // adapters, which bind them in the constructor.
        a.registry = _deployRegistry(a.dao);
        b.registry = _deployRegistry(b.dao);
        a.registry.setChainIdPair(_bChainId, _bSelector);
        b.registry.setChainIdPair(_aChainId, _aSelector);

        // Each adapter trusts the REMOTE CONTROLLER, never the remote adapter:
        // the send path is `delegatecall`ed, so the bridge attributes the
        // message to the controller.
        a.adapter = new CCIPAdapter(
            address(a.controller),
            address(a.router),
            _feeToken,
            address(a.registry),
            _trustedRemotes(_bChainId, address(b.controller))
        );
        b.adapter = new CCIPAdapter(
            address(b.controller),
            address(b.router),
            _feeToken,
            address(b.registry),
            _trustedRemotes(_aChainId, address(a.controller))
        );

        a.target = new GuardedTarget();
        b.target = new GuardedTarget();

        _label(a, "A");
        _label(b, "B");

        _grantStackPermissions(a);
        _grantStackPermissions(b);

        // The lane is keyed by the REMOTE chain id and serves both directions:
        // it is the send route out, and the authorization of the local adapter
        // for inbound messages from that chain.
        _configureLane(a, _bChainId, address(b.adapter));
        _configureLane(b, _aChainId, address(a.adapter));
    }

    /// @notice The chain id table one stack's adapter resolves lanes through.
    /// @dev Deployed BEFORE the adapter that binds it: constructor-only, no
    ///      setter. This test contract holds ROOT on the DAO, so it grants
    ///      itself the manager permission and seeds directly. A real deployment
    ///      makes the same two calls through governance -- see
    ///      `CrossChainDeploy._deployRegistries`.
    function _deployRegistry(DAO _dao) internal returns (ChainIdRegistry registry_) {
        registry_ = new ChainIdRegistry(IDAO(address(_dao)));
        _dao.grant(address(registry_), address(this), Permissions.MANAGE_CHAIN_ID_REGISTRY_PERMISSION_ID);
    }

    /// @notice Deploys a real `DAO` behind an ERC-1967 proxy, with this test
    ///         contract as the initial ROOT holder.
    /// @dev The test contract keeps ROOT so it can grant and revoke at will; in
    ///      production that is the DAO itself after the setup handover.
    /// @param _daoLabel A `vm.label` for readable traces.
    function _deployDao(string memory _daoLabel) internal returns (DAO dao_) {
        DAO impl = new DAO();

        dao_ = DAO(
            payable(ProxyLib.deployUUPSProxy(
                    address(impl), abi.encodeCall(DAO.initialize, (DAO_METADATA, address(this), address(0), DAO_URI))
                ))
        );

        vm.label(address(dao_), _daoLabel);
    }

    /// @notice Deploys a controller proxy owned by `_dao` and pointed at
    ///         `_executor`.
    function _deployController(DAO _dao, Executor _executor) internal returns (CrossChainController) {
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

    /// @notice Grants the full permission set a production stack needs, through
    ///         the real `PermissionManager`.
    /// @dev `FORWARD_MESSAGE_PERMISSION` goes to the DAO itself, because a
    ///      cross-chain send is produced by a passed proposal: the DAO executes
    ///      an action that calls `forwardMessage`. See `_forwardViaProposal`.
    function _grantStackPermissions(Stack memory _stack) internal {
        DAO dao = _stack.dao;
        address controller = address(_stack.controller);

        // The governance plugin is what executes proposals on the DAO.
        dao.grant(address(dao), plugin, Permissions.EXECUTE_PERMISSION_ID);

        // Outbound and operational permissions, held by the DAO.
        dao.grant(controller, address(dao), Permissions.FORWARD_MESSAGE_PERMISSION_ID);
        dao.grant(controller, address(dao), Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID);
        dao.grant(controller, address(dao), Permissions.CANCEL_MESSAGE_PERMISSION_ID);
        dao.grant(controller, address(dao), Permissions.SWEEP_PERMISSION_ID);
        dao.grant(controller, address(dao), Permissions.UNPAUSE_PERMISSION_ID);

        // Retry is held by an ops account, never by the execution target.
        dao.grant(controller, ops, Permissions.RETRY_MESSAGE_PERMISSION_ID);

        // The guardian may freeze, never reopen.
        dao.grant(controller, guardian, Permissions.PAUSE_PERMISSION_ID);
    }

    /// @notice Configures one lane on a controller, acting as the DAO.
    /// @dev Pranks the DAO rather than granting this test contract the
    ///      permission, so the call travels the same authorization path a
    ///      passed proposal would.
    /// @param _stack The local stack.
    /// @param _remoteChainId The standard chain id of the counterparty.
    /// @param _remoteAdapter The counterparty's ADAPTER (the CCIP receiver).
    function _configureLane(Stack memory _stack, uint256 _remoteChainId, address _remoteAdapter) internal {
        _configureLaneWithLocalAdapter(_stack, _remoteChainId, address(_stack.adapter), _remoteAdapter);
    }

    /// @notice Configures a lane whose LOCAL adapter is something other than the
    ///         stack's own -- a codeless address, a stale adapter, a
    ///         deliberately broken one.
    function _configureLaneWithLocalAdapter(
        Stack memory _stack,
        uint256 _remoteChainId,
        address _localAdapter,
        address _remoteAdapter
    )
        internal
    {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = _remoteChainId;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] = ICrossChainController.ChainConfig({ localAdapter: _localAdapter, remoteAdapter: _remoteAdapter });

        vm.prank(address(_stack.dao));
        _stack.controller.updateConfig(chainIds, configs);
    }

    /// @notice Clears a lane on a controller, acting as the DAO.
    function _clearLane(Stack memory _stack, uint256 _remoteChainId) internal {
        _configureLaneWithLocalAdapter(_stack, _remoteChainId, address(0), address(0));
    }

    /// @notice Repoints a stack at its own DAO as the execution target.
    /// @dev The OTHER wiring `CrossChainControllerSetup` supports: inbound
    ///      payloads run on the DAO itself, which needs the controller to hold
    ///      `EXECUTE_PERMISSION` on it. Materially different from the standalone
    ///      executor, because the DAO's reentrancy guard is then shared between
    ///      governance execution and cross-chain execution -- so a retry driven
    ///      by a proposal re-enters a guard that is already held.
    function _useDaoAsExecutor(Stack memory _stack) internal {
        _stack.dao.grant(address(_stack.dao), address(_stack.controller), Permissions.EXECUTE_PERMISSION_ID);

        vm.prank(address(_stack.dao));
        _stack.controller.updateExecutor(address(_stack.dao));
    }

    /// @dev Labels every contract of a stack for readable traces.
    function _label(Stack memory _stack, string memory _side) internal {
        vm.label(address(_stack.controller), string.concat("controller:", _side));
        vm.label(address(_stack.executor), string.concat("executor:", _side));
        vm.label(address(_stack.adapter), string.concat("adapter:", _side));
        vm.label(address(_stack.router), string.concat("router:", _side));
        vm.label(address(_stack.target), string.concat("target:", _side));
    }

    /// @dev Builds the single-entry trusted-remote config an adapter takes.
    function _trustedRemotes(uint256 _chainId, address _remoteController)
        internal
        pure
        returns (BaseAdapter.TrustedRemoteConfig[] memory configs)
    {
        configs = new BaseAdapter.TrustedRemoteConfig[](1);
        configs[0] = BaseAdapter.TrustedRemoteConfig({ standardChainId: _chainId, trustedRemote: _remoteController });
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
    // Sending.
    // -------------------------------------------------------------------------

    /// @notice Sends a message the way production does: a passed proposal is
    ///         executed on the origin DAO, and one of its actions calls
    ///         `forwardMessage` on the controller.
    /// @param _from The origin stack.
    /// @param _to The destination stack.
    /// @param _gasLimit The destination gas limit to request.
    /// @param _payload The encoded `Action[]` to run on the destination.
    /// @return txId The controller's transaction id for the message.
    function _forwardViaProposal(Stack memory _from, Stack memory _to, uint256 _gasLimit, bytes memory _payload)
        internal
        returns (bytes32 txId)
    {
        uint256 previous = block.chainid;
        _on(_from);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            to: address(_from.controller),
            value: 0,
            data: abi.encodeCall(ICrossChainController.forwardMessage, (_to.chainId, _gasLimit, _payload))
        });

        vm.prank(plugin);
        (bytes[] memory results,) = _from.dao.execute(keccak256("proposal"), actions, 0);

        txId = abi.decode(results[0], (bytes32));

        vm.chainId(previous);
    }

    /// @notice Sends a message directly as the DAO, skipping the proposal.
    /// @dev Shorter than `_forwardViaProposal` for tests whose subject is the
    ///      destination side rather than the origin's governance path.
    function _forwardAsDao(Stack memory _from, Stack memory _to, uint256 _gasLimit, bytes memory _payload)
        internal
        returns (bytes32 txId)
    {
        uint256 previous = block.chainid;
        _on(_from);

        vm.prank(address(_from.dao));
        txId = _from.controller.forwardMessage(_to.chainId, _gasLimit, _payload);

        vm.chainId(previous);
    }

    // -------------------------------------------------------------------------
    // Delivering.
    // -------------------------------------------------------------------------

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
    /// @dev This is how a test forges a delivery: a doctored sender, an unmapped
    ///      source selector, a replayed or tampered payload. The destination
    ///      router is the caller, so the adapter's `onlyRouter` check passes and
    ///      the test is about what happens AFTER it.
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
        return _forgeDeliveryRaw(_to, _messageId, _sourceSelector, abi.encode(_sender), _data, _gasLimit);
    }

    /// @notice `_forgeDelivery` with arbitrary sender BYTES, so a test can send
    ///         something that does not decode to an address at all.
    function _forgeDeliveryRaw(
        Stack memory _to,
        bytes32 _messageId,
        uint64 _sourceSelector,
        bytes memory _senderBytes,
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
                _any2Evm(_messageId, _sourceSelector, _senderBytes, _data), address(_to.adapter), _gasLimit
            );

        vm.chainId(previous);
    }

    /// @notice Builds the CCIP message shape a destination adapter receives.
    /// @dev For tests that call `ccipReceive` directly rather than going through
    ///      a router.
    function _any2Evm(bytes32 _messageId, uint64 _sourceSelector, bytes memory _senderBytes, bytes memory _data)
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: _messageId,
            sourceChainSelector: _sourceSelector,
            sender: _senderBytes,
            data: _data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    // -------------------------------------------------------------------------
    // Payloads.
    // -------------------------------------------------------------------------

    /// @notice The payload of a cross-chain proposal that calls the target.
    function _cancelPayload(Stack memory _to) internal pure returns (bytes memory) {
        return _actionPayload(address(_to.target), 0, abi.encodeCall(GuardedTarget.cancelRootUpdate, ()));
    }

    /// @notice A payload wrapping a single arbitrary action.
    function _actionPayload(address _to, uint256 _value, bytes memory _data) internal pure returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: _to, value: _value, data: _data });

        return abi.encode(actions);
    }

    /// @notice A payload wrapping an empty action array.
    function _emptyPayload() internal pure returns (bytes memory) {
        return abi.encode(new Action[](0));
    }

    /// @notice A payload of `_count` calls to the destination target.
    function _repeatedCancelPayload(Stack memory _to, uint256 _count) internal pure returns (bytes memory) {
        Action[] memory actions = new Action[](_count);
        for (uint256 i = 0; i < _count; i++) {
            actions[i] =
                Action({ to: address(_to.target), value: 0, data: abi.encodeCall(GuardedTarget.cancelRootUpdate, ()) });
        }

        return abi.encode(actions);
    }

    /// @notice Rebuilds the exact envelope bytes a send produced, so a test can
    ///         hand them to `retryMessage` or replay them by hand.
    function _encodedTx(Stack memory _from, Stack memory _to, uint256 _nonce, address _origin, bytes memory _message)
        internal
        pure
        returns (bytes memory)
    {
        return Transaction({
                nonce: _nonce,
                origin: _origin,
                controller: address(_from.controller),
                originChainId: _from.chainId,
                destinationChainId: _to.chainId,
                message: _message
            }).encode();
    }

    /// @notice The payload bytes of the message queued at `_index` on a router.
    /// @dev The router stores exactly what the adapter handed CCIP, so this is
    ///      the authoritative envelope for retry and replay tests.
    function _queuedPayload(Stack memory _from, uint256 _index) internal view returns (bytes memory) {
        return _from.router.sentAt(_index).data;
    }

    // -------------------------------------------------------------------------
    // Assertions.
    // -------------------------------------------------------------------------

    /// @notice Asserts a transaction reached `Executed` on the destination.
    function _assertExecuted(Stack memory _to, bytes32 _txId) internal view {
        assertEq(
            uint256(_to.controller.getTransactionState(_txId)),
            uint256(TransactionState.Executed),
            "transaction should be Executed"
        );
    }

    /// @notice Asserts a transaction was delivered but its payload failed, so it
    ///         is awaiting `retryMessage`.
    function _assertDelivered(Stack memory _to, bytes32 _txId) internal view {
        assertEq(
            uint256(_to.controller.getTransactionState(_txId)),
            uint256(TransactionState.Delivered),
            "transaction should be Delivered (failed, retryable)"
        );
    }

    /// @notice Asserts a transaction was cancelled.
    function _assertCancelled(Stack memory _to, bytes32 _txId) internal view {
        assertEq(
            uint256(_to.controller.getTransactionState(_txId)),
            uint256(TransactionState.Cancelled),
            "transaction should be Cancelled"
        );
    }

    /// @notice Asserts the destination has no record of a transaction, which is
    ///         the state after a BRIDGE-level delivery failure.
    function _assertUnknown(Stack memory _to, bytes32 _txId) internal view {
        assertEq(
            uint256(_to.controller.getTransactionState(_txId)),
            uint256(TransactionState.None),
            "transaction should be unknown to the destination"
        );
    }
}
