// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import { CrossChainController } from "@src/CrossChainController.sol";
import { Executor } from "@src/Executor.sol";
import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { ChainIds } from "@src/lib/ChainIds.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { TransactionLib } from "@src/lib/Transaction.sol";

import { CrossChainE2EBase } from "../Base.sol";
import { GuardedTarget } from "@mocks/E2ETargets.sol";

/// @notice The parts of the production CCIP `Router` this suite drives that are
///         not on `IRouterClient`.
interface IRouterFork {
    struct OffRamp {
        uint64 sourceChainSelector;
        address offRamp;
    }

    /// @notice Every OffRamp registered on this Router.
    function getOffRamps() external view returns (OffRamp[] memory);

    /// @notice Delivers a message to a receiver with EXACT gas. `onlyOffRamp`.
    function routeMessage(
        Client.Any2EVMMessage calldata message,
        uint16 gasForCallExactCheck,
        uint256 gasLimit,
        address receiver
    )
        external
        returns (bool success, bytes memory retData, uint256 gasUsed);

    function typeAndVersion() external view returns (string memory);
}

/// @title CCIPRealRouterForkTest
/// @notice The cross-chain stack running against the REAL, production Chainlink
///         CCIP Router bytecode on two real chains.
///
/// @dev WHAT THIS PROVES, and just as importantly what it does not.
///
///      PROVEN:
///      - our `Client.EVM2AnyMessage` is well-formed enough for the real mainnet
///        Router to price it, i.e. our `GenericExtraArgsV2` extraArgs are
///        accepted by the production OnRamp rather than silently defaulting or
///        reverting;
///      - a real `ccipSend` is ACCEPTED: the request is admitted and a message
///        id returned. That validates our calldata encoding, the native fee paid
///        out of the CONTROLLER's balance (the `delegatecall` consequence), and
///        the LINK `forceApprove` path, against real Router bytecode rather than
///        a mock we wrote ourselves;
///      - on the real destination chain, a real registered OffRamp calling the
///        real Router's `routeMessage` delivers to our adapter with real
///        exact-gas semantics, the trusted-remote check resolves the origin
///        CONTROLLER, and the destination executor runs the actions;
///      - the Router addresses and the WHOLE chain-selector table we hardcode in
///        `CCIPAdapter` are still current.
///
///      NOT PROVEN, and no fork test can prove it:
///      - the DON transport itself. Nothing here waits for or exercises
///        committing, blessing or execution by the oracle network;
///      - that a lane is un-cursed and within its rate limits at the moment you
///        deploy. `getFee` succeeding implies the lane exists at the forked
///        block and says nothing about future config;
///      - real delivery latency or the smart-execution window.
///
///      DELIVERY MECHANISM. `Router.routeMessage` is `onlyOffRamp` and applies
///      `CallWithExactGas`, so pranking a REAL registered OffRamp into it is the
///      highest-fidelity delivery available without the DON: real Router, real
///      caller-authorisation path, real gas semantics. It is strictly better
///      than pranking the Router into `adapter.ccipReceive` directly, which
///      skips the Router's own logic entirely.
///
///      RUNNING IT. Needs `MAINNET_RPC_URL` and `BASE_RPC_URL`; every test skips
///      cleanly when they are missing, so the default `forge test` is unchanged.
contract CCIPRealRouterForkTest is CrossChainE2EBase {
    /// @dev Verified on-chain via `typeAndVersion()`;
    ///      `test_fork_routerAddressesAreCurrent` re-checks it every run.
    address internal constant MAINNET_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address internal constant MAINNET_LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    /// @dev Mirrors the real Router's own constant.
    uint16 internal constant GAS_FOR_CALL_EXACT_CHECK = 5_000;

    uint256 internal ethFork;
    uint256 internal baseFork;

    /// @dev One controller implementation PER FORK. Solidity state survives
    ///      `vm.selectFork`, but deployed code does not: an implementation
    ///      deployed on Base is a codeless address on mainnet, and ERC-1967
    ///      rejects it. Anything that deploys a proxy has to pick the right one
    ///      for the fork it is on.
    address internal ethControllerImplementation;
    address internal baseControllerImplementation;

    /// @dev False when the RPC endpoints are missing, in which case every test
    ///      skips instead of failing.
    bool internal forksReady;

    /// @dev Skips the test cleanly when the endpoints are not configured.
    modifier withForks() {
        if (!forksReady) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Replaces the mock-lane fixture entirely: the stacks here live on two
    ///      real forks. `Stack.router` is deliberately left unset -- it types the
    ///      mock transport, which has no place in this suite -- so none of the
    ///      base's `_deliver*` helpers may be used. Delivery goes through
    ///      `_deliverToBase` below.
    function setUp() public virtual override {
        string memory ethRpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(ethRpc).length == 0) {
            ethRpc = vm.envOr("RPC_URL", string(""));
        }
        string memory baseRpc = vm.envOr("BASE_RPC_URL", string(""));

        if (bytes(ethRpc).length == 0 || bytes(baseRpc).length == 0) return;

        ethFork = vm.createFork(ethRpc);
        baseFork = vm.createFork(baseRpc);
        forksReady = true;

        origin.chainId = ChainIds.ETHEREUM;
        origin.selector = ORIGIN_SELECTOR;
        destination.chainId = ChainIds.BASE;
        destination.selector = DESTINATION_SELECTOR;

        // Controllers on BOTH chains first: each adapter bakes the remote
        // controller in at construction and offers no setter afterwards. Note
        // the implementation is redeployed per fork -- code deployed on one fork
        // does not exist on the other.
        vm.selectFork(ethFork);
        ethControllerImplementation = address(new CrossChainController());
        controllerImplementation = ethControllerImplementation;
        origin.dao = _deployDao("dao:ETH");
        origin.executor = new Executor();
        origin.controller = _deployController(origin.dao, origin.executor);
        origin.executor.transferOwnership(address(origin.controller));
        origin.target = new GuardedTarget();

        vm.selectFork(baseFork);
        baseControllerImplementation = address(new CrossChainController());
        controllerImplementation = baseControllerImplementation;
        destination.dao = _deployDao("dao:BASE");
        destination.executor = new Executor();
        destination.controller = _deployController(destination.dao, destination.executor);
        destination.executor.transferOwnership(address(destination.controller));
        destination.target = new GuardedTarget();

        // Adapters, then wiring, on each side.
        vm.selectFork(ethFork);
        origin.adapter = new CCIPAdapter(
            address(origin.controller),
            MAINNET_ROUTER,
            address(0),
            _trustedRemotes(destination.chainId, address(destination.controller))
        );

        vm.selectFork(baseFork);
        destination.adapter = new CCIPAdapter(
            address(destination.controller),
            BASE_ROUTER,
            address(0),
            _trustedRemotes(origin.chainId, address(origin.controller))
        );
        _grantStackPermissions(destination);
        _configureLane(destination, origin.chainId, address(origin.adapter));

        vm.selectFork(ethFork);
        _grantStackPermissions(origin);
        _configureLane(origin, destination.chainId, address(destination.adapter));
        vm.deal(address(origin.controller), 100 ether);
    }

    // -------------------------------------------------------------------------
    // Origin half: the real mainnet Router.
    // -------------------------------------------------------------------------

    /// @notice The real Router prices our message, and the quote is sane.
    /// @dev A malformed `extraArgs` tag would revert here rather than return a
    ///      number, so this doubles as an encoding check.
    function test_fork_realRouterQuotesASaneFee() public withForks {
        vm.selectFork(ethFork);

        (address token, uint256 fee,) =
            origin.controller.quoteFee(destination.chainId, GAS_LIMIT, _cancelPayload(destination));

        assertEq(token, address(0), "native lane");
        assertGt(fee, 0, "a real lane must cost something");
        assertLt(fee, 1 ether, "and not an absurd amount");
    }

    /// @notice The quote rises with the requested gas limit, which proves the
    ///         limit inside `extraArgs` actually reaches the OnRamp.
    /// @dev If the tag or field order were wrong, CCIP would fall back to its
    ///      default and both quotes would be identical.
    function test_fork_quoteIsMonotonicInTheGasLimit() public withForks {
        vm.selectFork(ethFork);

        bytes memory payload = _cancelPayload(destination);

        (, uint256 cheap,) = origin.controller.quoteFee(destination.chainId, 100_000, payload);
        (, uint256 dear,) = origin.controller.quoteFee(destination.chainId, 2_000_000, payload);

        assertGt(dear, cheap, "the extraArgs gas limit must reach the OnRamp");
    }

    /// @notice A real `ccipSend`, paid in native currency, is accepted by the
    ///         real Router, and the fee leaves the CONTROLLER's balance.
    function test_fork_realRouterAcceptsNativeFeeSend() public withForks {
        vm.selectFork(ethFork);

        (, uint256 fee,) = origin.controller.quoteFee(destination.chainId, GAS_LIMIT, _cancelPayload(destination));

        uint256 controllerBefore = address(origin.controller).balance;
        uint256 daoBefore = address(origin.dao).balance;

        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, _cancelPayload(destination));

        assertTrue(txId != bytes32(0));
        assertEq(address(origin.controller).balance, controllerBefore - fee, "the controller pays the real fee");
        assertEq(address(origin.dao).balance, daoBefore, "the treasury is untouched");
        assertEq(address(origin.adapter).balance, 0, "the adapter holds nothing");
    }

    /// @notice The ERC20 (LINK) fee path -- the `forceApprove` half -- against
    ///         real Router bytecode.
    function test_fork_realRouterAcceptsLinkFeeSend() public withForks {
        vm.selectFork(ethFork);

        // A LINK-fee stack, wired like the native one. The implementation must
        // be the one deployed on THIS fork.
        controllerImplementation = ethControllerImplementation;

        Executor linkExecutor = new Executor();
        CrossChainController linkController = _deployController(origin.dao, linkExecutor);
        linkExecutor.transferOwnership(address(linkController));

        CCIPAdapter linkAdapter = new CCIPAdapter(
            address(linkController),
            MAINNET_ROUTER,
            MAINNET_LINK,
            _trustedRemotes(destination.chainId, address(destination.controller))
        );

        origin.dao.grant(address(linkController), address(origin.dao), Permissions.FORWARD_MESSAGE_PERMISSION_ID);
        origin.dao
            .grant(address(linkController), address(origin.dao), Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID);

        Stack memory linkStack = origin;
        linkStack.controller = linkController;
        linkStack.adapter = linkAdapter;
        _configureLane(linkStack, destination.chainId, address(destination.adapter));

        (, uint256 fee,) = linkController.quoteFee(destination.chainId, GAS_LIMIT, _cancelPayload(destination));
        assertGt(fee, 0);

        deal(MAINNET_LINK, address(linkController), fee * 2);

        vm.prank(address(origin.dao));
        linkController.forwardMessage(destination.chainId, GAS_LIMIT, _cancelPayload(destination));

        assertEq(
            IERC20(MAINNET_LINK).balanceOf(address(linkController)),
            fee,
            "exactly the quoted LINK must have been pulled"
        );
        assertEq(
            IERC20(MAINNET_LINK).allowance(address(linkController), MAINNET_ROUTER),
            0,
            "no standing allowance may be left behind"
        );
    }

    // -------------------------------------------------------------------------
    // The full loop across two real chains.
    // -------------------------------------------------------------------------

    /// @notice Send through the real mainnet Router, deliver through the real
    ///         Base Router, execute on the real destination executor.
    function test_fork_roundTripAcrossRealRouters() public withForks {
        vm.selectFork(ethFork);

        bytes memory payload = _cancelPayload(destination);
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);

        bytes memory encodedTx = _encodedTx(origin, destination, 1, address(origin.dao), payload);
        assertEq(TransactionLib.id(encodedTx), txId, "the envelope must match");

        (bool success,) = _deliverToBase(keccak256("real-round-trip"), address(origin.controller), encodedTx, GAS_LIMIT);

        assertTrue(success, "the real Router must have delivered");
        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
        assertEq(destination.target.lastCaller(), address(destination.executor));
    }

    /// @notice Under-gassed delivery through the REAL Router returns
    ///         `success == false` rather than reverting, stores nothing, and is
    ///         re-executable with more gas.
    /// @dev This is CCIP manual execution, on production bytecode. It confirms
    ///      the third gas regime from `GasLimits.t.sol` is real and not an
    ///      artefact of the mock transport.
    function test_fork_underGassedDeliveryIsRecoverable() public withForks {
        vm.selectFork(ethFork);

        bytes memory payload = _cancelPayload(destination);
        bytes32 txId = _forwardViaProposal(origin, destination, GAS_LIMIT, payload);
        bytes memory encodedTx = _encodedTx(origin, destination, 1, address(origin.dao), payload);

        (bool starved,) = _deliverToBase(keccak256("starved"), address(origin.controller), encodedTx, 30_000);

        assertFalse(starved, "the delivery must fail at the bridge level");
        _assertUnknown(destination, txId);

        (bool retried,) = _deliverToBase(keccak256("starved"), address(origin.controller), encodedTx, GAS_LIMIT);

        assertTrue(retried, "manual re-execution must succeed");
        _assertExecuted(destination, txId);
    }

    /// @notice On the real destination chain, a delivery attributed to anyone
    ///         other than the origin CONTROLLER is rejected.
    function test_fork_untrustedSenderIsRejectedOnTheRealChain() public withForks {
        vm.selectFork(ethFork);

        bytes memory encodedTx = _encodedTx(origin, destination, 1, address(origin.dao), _cancelPayload(destination));

        (bool success, bytes memory reason) =
            _deliverToBase(keccak256("forged"), address(origin.adapter), encodedTx, GAS_LIMIT);

        assertFalse(success, "the remote ADAPTER is not the trusted remote");
        assertEq(reason, abi.encodeWithSelector(Errors.REMOTE_NOT_TRUSTED.selector));
        assertEq(destination.target.cancellations(), 0);
    }

    /// @notice Only the real Router may reach the adapter.
    function test_fork_onlyTheRealRouterMayDeliver() public withForks {
        vm.selectFork(baseFork);

        vm.prank(stranger);
        vm.expectRevert(Errors.CALLER_NOT_CCIP_ROUTER.selector);
        destination.adapter
            .ccipReceive(
                _any2Evm(
                    keccak256("forged"),
                    ORIGIN_SELECTOR,
                    abi.encode(address(origin.controller)),
                    _cancelPayload(destination)
                )
            );
    }

    // -------------------------------------------------------------------------
    // Staleness guards.
    // -------------------------------------------------------------------------

    /// @notice The Router addresses we hardcode still hold a CCIP Router.
    /// @dev Asserted on the `typeAndVersion` PREFIX rather than the exact string
    ///      so a Router minor-version bump does not fail the suite, while an
    ///      address that stopped being a Router at all still does.
    function test_fork_routerAddressesAreCurrent() public withForks {
        vm.selectFork(ethFork);
        _assertIsARouter(MAINNET_ROUTER, "mainnet");

        vm.selectFork(baseFork);
        _assertIsARouter(BASE_ROUTER, "base");
    }

    /// @notice EVERY chain in the adapter's hardcoded selector table carries the
    ///         selector Chainlink actually assigned it, is a live CCIP lane from
    ///         mainnet, and inverts cleanly.
    /// @dev THE REASON THIS SUITE EXISTS. The table is compiled in and cannot be
    ///      fixed without redeploying the adapter, so a wrong entry has to be
    ///      caught before deployment.
    ///
    ///      THREE INDEPENDENT CHECKS, because no one of them is sufficient:
    ///
    ///      1. GROUND TRUTH. The selector must equal the value in
    ///         `_chainSelectorPairs`, transcribed from Chainlink's
    ///         `chain-selectors` registry. This is the only check that catches a
    ///         CONSISTENTLY mis-paired entry -- copying the wrong row of the
    ///         directory, so a chain is mapped to some OTHER live chain's
    ///         selector. Such an entry is a live lane and inverts perfectly, so
    ///         checks 2 and 3 both pass while messages silently route to the
    ///         wrong chain. That is the likeliest typo when adding a chain, and
    ///         the reason this check leads.
    ///      2. LIVENESS. The real mainnet Router must still serve the lane, which
    ///         ground truth alone cannot tell you -- Chainlink retires lanes.
    ///      3. INVERSION. `fromNativeChainId` must undo `toNativeChainId`, since
    ///         the two tables are maintained by hand and separately.
    ///
    ///      COVERAGE IS PINNED, NOT FLOORED. `_MAPPED_CHAIN_COUNT` is an exact
    ///      equality: a chain silently dropping out of the table fails here
    ///      rather than quietly shrinking what is checked. Editing `ChainIds` is
    ///      meant to require bumping that constant -- the friction is the point.
    function test_fork_everyMappedSelectorIsALiveLane() public withForks {
        vm.selectFork(ethFork);

        uint256[2][] memory pairs = _chainSelectorPairs();
        uint256 mapped;

        for (uint256 i = 0; i < pairs.length; i++) {
            uint256 chainId = pairs[i][0];
            uint64 expectedSelector = uint64(pairs[i][1]);

            uint64 selector;
            try origin.adapter.toNativeChainId(chainId) returns (uint256 nativeChainId) {
                // forge-lint: disable-next-line(unsafe-typecast)
                selector = uint64(nativeChainId);
            } catch {
                // Not in the table; nothing to check.
                continue;
            }

            mapped++;

            // 1. Ground truth.
            assertEq(
                uint256(selector),
                uint256(expectedSelector),
                string.concat("wrong CCIP selector for chain ", vm.toString(chainId))
            );

            // 3. Inversion.
            assertEq(
                origin.adapter.fromNativeChainId(selector),
                chainId,
                string.concat("the table must invert for chain ", vm.toString(chainId))
            );

            // 2. Liveness. A Router serves no lane to its OWN chain:
            // `isChainSupported` is false for Ethereum on the Ethereum Router,
            // and that is correct, not stale. The same-chain case is a local
            // concern, covered by `test/unit/CrossChainController/sameChainLane.t.sol`.
            if (chainId == ChainIds.ETHEREUM) continue;

            assertTrue(
                IRouterClient(MAINNET_ROUTER).isChainSupported(selector),
                string.concat("no live mainnet lane for chain ", vm.toString(chainId))
            );
        }

        assertEq(
            mapped,
            _MAPPED_CHAIN_COUNT,
            "the adapter maps a different number of chains than expected -- update _MAPPED_CHAIN_COUNT, and make sure "
            "any newly mapped chain is present in _chainSelectorPairs so it is actually checked"
        );
    }

    /// @notice The adapter is recognised as a CCIP receiver by the real Router's
    ///         ERC165 probe.
    /// @dev A false here would make the production Router SKIP delivery and
    ///      report success, losing every inbound message silently.
    function test_fork_adapterIsRecognisedAsACcipReceiver() public withForks {
        vm.selectFork(baseFork);

        assertTrue(destination.adapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    }

    // -------------------------------------------------------------------------
    // Helpers.
    // -------------------------------------------------------------------------

    /// @dev EXACTLY how many chains `CCIPAdapter.toNativeChainId` must map, of
    ///      the pairs below.
    ///
    ///      Deliberately an exact count, not a floor: with a floor, a chain
    ///      quietly disappearing from the table still passes, and the suite
    ///      silently checks less than it advertises. Bump this when `ChainIds`
    ///      gains or loses a chain -- and when you do, add the new chain to
    ///      `_chainSelectorPairs`, or the count will match while the new entry
    ///      goes unchecked.
    uint256 internal constant _MAPPED_CHAIN_COUNT = 15;

    /// @dev `(standard chain id, CCIP chain selector)` ground truth, transcribed
    ///      from Chainlink's `chain-selectors` registry:
    ///      https://github.com/smartcontractkit/chain-selectors/blob/main/selectors.yml
    ///
    ///      A SUPERSET of what the adapter maps: ids absent from the adapter's
    ///      table are skipped, so chains can be added to or removed from
    ///      `ChainIds` without editing this, as long as the chain is listed
    ///      here. Entries beyond the adapter's current table are candidates for
    ///      future lanes, pre-verified so adding one is a one-line change.
    ///
    ///      These values are the AUTHORITY the adapter is checked against, so
    ///      they must be copied from the registry rather than from
    ///      `CCIPAdapter` -- copying from the code under test would make the
    ///      ground-truth check circular and worthless.
    function _chainSelectorPairs() internal pure returns (uint256[2][] memory pairs) {
        pairs = new uint256[2][](24);
        pairs[0] = [uint256(1), 5009297550715157269]; // Ethereum
        pairs[1] = [uint256(10), 3734403246176062136]; // Optimism
        pairs[2] = [uint256(25), 1456215246176062136]; // Cronos
        pairs[3] = [uint256(56), 11344663589394136015]; // BNB
        pairs[4] = [uint256(100), 465200170687744372]; // Gnosis
        pairs[5] = [uint256(130), 1923510103922296319]; // Unichain
        pairs[6] = [uint256(137), 4051577828743386545]; // Polygon
        pairs[7] = [uint256(143), 8481857512324358265]; // Monad
        pairs[8] = [uint256(146), 1673871237479749969]; // Sonic
        pairs[9] = [uint256(250), 3768048213127883732]; // Fantom
        pairs[10] = [uint256(324), 1562403441176082196]; // zkSync Era
        pairs[11] = [uint256(480), 2049429975587534727]; // World Chain
        pairs[12] = [uint256(999), 2442541497099098535]; // HyperEVM
        pairs[13] = [uint256(1868), 12505351618335765396]; // Soneium
        pairs[14] = [uint256(4326), 6093540873831549674]; // MegaETH
        pairs[15] = [uint256(5000), 1556008542357238666]; // Mantle
        pairs[16] = [uint256(8453), 15971525489660198786]; // Base
        pairs[17] = [uint256(9745), 9335212494177455608]; // Plasma
        pairs[18] = [uint256(42161), 4949039107694359620]; // Arbitrum One
        pairs[19] = [uint256(42220), 1346049177634351622]; // Celo
        pairs[20] = [uint256(43114), 6433500567565415381]; // Avalanche
        pairs[21] = [uint256(57073), 3461204551265785888]; // Ink
        pairs[22] = [uint256(59144), 4627098889531055414]; // Linea
        pairs[23] = [uint256(747474), 2459028469735686113]; // Katana
    }

    /// @dev Asserts the address still exposes a CCIP `Router` `typeAndVersion`.
    function _assertIsARouter(address _router, string memory _label) internal view {
        string memory version = IRouterFork(_router).typeAndVersion();

        assertTrue(
            bytes(version).length >= 6 && _startsWith(version, "Router"),
            string.concat(_label, " router address is stale, typeAndVersion() = ", version)
        );
    }

    function _startsWith(string memory _value, string memory _prefix) internal pure returns (bool) {
        bytes memory value = bytes(_value);
        bytes memory prefix = bytes(_prefix);

        if (value.length < prefix.length) return false;

        for (uint256 i = 0; i < prefix.length; i++) {
            if (value[i] != prefix[i]) return false;
        }

        return true;
    }

    /// @notice Delivers a message to the destination adapter by pranking a REAL
    ///         registered OffRamp into the REAL Router's `routeMessage`.
    /// @dev Tries every OffRamp registered for the mainnet source selector:
    ///      Routers carry historical ramps, and only the current one is
    ///      necessarily usable. Reverting attempts are skipped, and a genuine
    ///      application-level rejection (which RETURNS false rather than
    ///      reverting) is reported back to the caller.
    /// @param _messageId The bridge-level id to claim.
    /// @param _sender The origin-chain address to attribute the message to.
    /// @param _data The envelope bytes.
    /// @param _gasLimit The exact gas to give the adapter.
    /// @return success Whether `ccipReceive` succeeded.
    /// @return returnData Its revert data when it did not.
    function _deliverToBase(bytes32 _messageId, address _sender, bytes memory _data, uint256 _gasLimit)
        internal
        returns (bool success, bytes memory returnData)
    {
        vm.selectFork(baseFork);

        Client.Any2EVMMessage memory message = _any2Evm(_messageId, ORIGIN_SELECTOR, abi.encode(_sender), _data);

        IRouterFork.OffRamp[] memory offRamps = IRouterFork(BASE_ROUTER).getOffRamps();

        for (uint256 i = offRamps.length; i > 0; i--) {
            IRouterFork.OffRamp memory ramp = offRamps[i - 1];
            if (ramp.sourceChainSelector != ORIGIN_SELECTOR) continue;

            vm.prank(ramp.offRamp);
            try IRouterFork(BASE_ROUTER)
                .routeMessage(
                    message, GAS_FOR_CALL_EXACT_CHECK, _gasLimit, address(destination.adapter)
                ) returns (bool ok, bytes memory data, uint256) {
                return (ok, data);
            } catch {
                // A retired ramp; try the next one.
                continue;
            }
        }

        revert("no usable Base OffRamp for the mainnet lane");
    }
}
