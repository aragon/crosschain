// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { CrossChainController } from "@src/CrossChainController.sol";
import { ICrossChainController } from "@src/ICrossChainController.sol";
import { TransactionRecord } from "@src/lib/Transaction.sol";
import { Executor } from "@src/Executor.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { Permissions } from "@src/lib/Permissions.sol";

import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import { ProxyLib } from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";

import { CrossChainControllerDAOMock } from "@mocks/CrossChainControllerDAOMock.sol";

import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { TestnetCCIPAdapter } from "./TestnetCCIPAdapter.sol";

/// STEP 1:
/// Bridge to Arb Sepolia: https://bridge.arbitrum.io/?sourceChain=sepolia&destinationChain=arbitrum-sepolia
/// Bridge to Base Sepolia: https://testnets.superbridge.app/base-sepolia
/// STEP 2: Include these in .env:
///     PRIVATE_KEY=
///     ARBITRUM_SEPOLIA_RPC=
///     BASE_SEPOLIA_RPC=
/// STEP 3: run the following command:
///     forge script script/testnet/Test_Deploy.s.sol:Test_Deploy --sig "run()" --broadcast --multi

/// @notice The contract delivered actions operate on, deployed on both chains.
/// @dev TESTNET ONLY. `count` is readable proof that a message actually
///      executed, rather than inferring it from the absence of a failure.
contract CounterTarget {
    uint256 public count1;
    uint256 public count2;
    uint256 public count3;

    uint256 public count4;
    uint256 public count5;
    uint256 public count6;

    function incrementA() external {
        count1 += 1;
        count2 += 1;
        count3 += 1;
    }

    function incrementB() external {
        count4 += 1;
        count5 += 1;
        count6 += 1;
    }
}

/// @title Test_Deploy
/// @notice Stands up a live CCIP lane between Arbitrum Sepolia and Base Sepolia
///         in ONE run, so the under-gassed / manual-execution behaviour can be
///         observed against the REAL OffRamp and DON.
///
/// @dev TESTNET ONLY. `CrossChainControllerDAOMock` is the permission manager
///      and native ETH is the fee token.
///
///      WHY THE DEPLOY ORDER LOOKS ODD. `CCIPAdapter` takes its trusted remote
///      in the CONSTRUCTOR and exposes no setter, and each side must trust the
///      OTHER side's CONTROLLER -- the send path is a `delegatecall`, so CCIP
///      attributes the message to the controller, never the adapter. So no
///      adapter can be built until BOTH controllers exist. The script therefore
///      does: controllers on both chains, then adapters on both chains, then
///      lane config on both chains -- hopping forks between each pass.
///
///      Fork switching is what makes this a single command: `vm.selectFork`
///      moves execution between the two live networks, and each
///      `startBroadcast` block is recorded against whichever fork is active.
///
///      RUN
///        forge script script/testnet/Test_Deploy.s.sol:Test_Deploy \
///          --sig "run()" --broadcast --multi
///
///      `--multi` is REQUIRED: it tells Forge to keep a separate broadcast
///      bundle per chain. Without it only the last fork's transactions are
///      submitted.
///
///      ENV
///        PRIVATE_KEY deployer key, funded with testnet ETH on BOTH chains
///        ARBITRUM_SEPOLIA_RPC Arbitrum Sepolia RPC url
///        BASE_SEPOLIA_RPC Base Sepolia RPC url
///        FUND_AMOUNT_WEI optional; native pre-funding per controller
///                              (default 0.02 ether)
contract Test_Deploy is Script {
    uint256 internal constant ARBITRUM_SEPOLIA = 421_614;
    uint256 internal constant BASE_SEPOLIA = 84_532;

    /// @dev CCIP Routers, from the official directory (cross-checked against
    ///      `lib/chainlink-local/src/ccip/Register.sol`).
    address internal constant ARB_SEPOLIA_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address internal constant BASE_SEPOLIA_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;

    /// @notice Gas withheld so a failed inbound message is still recorded as
    ///         `Delivered`. See `CrossChainController.initialize`.
    uint256 internal constant MIN_FAILED_MESSAGE_GAS = 45_000;

    /// @notice Native ETH as the fee token; no LINK faucet needed.
    address internal constant FEE_TOKEN = address(0);

    /// @notice One chain's deployment.
    struct Deployment {
        uint256 forkId;
        uint256 chainId;
        address router;
        CrossChainControllerDAOMock dao;
        CrossChainController controller;
        Executor executor;
        TestnetCCIPAdapter adapter;
        CounterTarget target;
    }

    Deployment internal arbSepolia;
    Deployment internal baseSepolia;

    uint256 internal deployerKey;
    address internal deployer;

    function run() external {
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        uint256 fundAmount = vm.envOr("FUND_AMOUNT_WEI", uint256(0.03 ether));

        arbSepolia.forkId = vm.createFork(vm.envString("ARBITRUM_SEPOLIA_RPC"));
        arbSepolia.chainId = ARBITRUM_SEPOLIA;
        arbSepolia.router = ARB_SEPOLIA_ROUTER;

        baseSepolia.forkId = vm.createFork(vm.envString("BASE_SEPOLIA_RPC"));
        baseSepolia.chainId = BASE_SEPOLIA;
        baseSepolia.router = BASE_SEPOLIA_ROUTER;

        // Pass 1: controllers on both chains.
        _deployControllers(arbSepolia);
        _deployControllers(baseSepolia);

        // Pass 2: adapters -- now that both controller addresses are known,
        // each side can bake in the other's controller as its trusted remote.
        _deployAdapter(arbSepolia, baseSepolia);
        _deployAdapter(baseSepolia, arbSepolia);

        // Pass 3: lane config + fee pre-funding.
        _wireLane(arbSepolia, baseSepolia, fundAmount);
        _wireLane(baseSepolia, arbSepolia, fundAmount);

        _report();

        // Pass 4: the experiment itself. Done here, in the same run, while every
        // address is still in scope -- a separate `forge script` invocation
        // starts a fresh EVM where these storage vars would be empty again.
        _sendUnderGassed(arbSepolia, baseSepolia);
    }

    // -------------------------------------------------------------------------
    // Passes
    // -------------------------------------------------------------------------

    function _deployControllers(Deployment storage _d) internal {
        vm.selectFork(_d.forkId);
        require(block.chainid == _d.chainId, "Test_Deploy: RPC chain id mismatch");

        vm.startBroadcast(deployerKey);

        _d.dao = new CrossChainControllerDAOMock();
        _d.executor = new Executor();
        _d.target = new CounterTarget();

        _d.controller = CrossChainController(
            payable(ProxyLib.deployUUPSProxy(
                    address(new CrossChainController()),
                    abi.encodeCall(
                        CrossChainController.initialize,
                        (IDAO(address(_d.dao)), address(_d.executor), MIN_FAILED_MESSAGE_GAS)
                    )
                ))
        );

        // Only the controller may execute inbound payloads.
        _d.executor.transferOwnership(address(_d.controller));

        // The deployer drives every path in this experiment.
        _grant(_d, Permissions.FORWARD_MESSAGE_PERMISSION_ID);
        _grant(_d, Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID);
        _grant(_d, Permissions.RETRY_MESSAGE_PERMISSION_ID);
        _grant(_d, Permissions.CANCEL_MESSAGE_PERMISSION_ID);
        _grant(_d, Permissions.SWEEP_PERMISSION_ID);
        _grant(_d, Permissions.PAUSE_PERMISSION_ID);
        _grant(_d, Permissions.UNPAUSE_PERMISSION_ID);

        vm.stopBroadcast();
    }

    function _deployAdapter(Deployment storage _local, Deployment storage _remote) internal {
        vm.selectFork(_local.forkId);

        vm.startBroadcast(deployerKey);

        // Trust the REMOTE CONTROLLER, never the remote adapter.
        BaseAdapter.TrustedRemoteConfig[] memory trusted = new BaseAdapter.TrustedRemoteConfig[](1);
        trusted[0] = BaseAdapter.TrustedRemoteConfig({
            standardChainId: _remote.chainId, trustedRemote: address(_remote.controller)
        });

        _local.adapter = new TestnetCCIPAdapter(address(_local.controller), _local.router, FEE_TOKEN, trusted);

        vm.stopBroadcast();
    }

    function _wireLane(Deployment storage _local, Deployment storage _remote, uint256 _fundAmount) internal {
        vm.selectFork(_local.forkId);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = _remote.chainId;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] = ICrossChainController.ChainConfig({
            localAdapter: address(_local.adapter), remoteAdapter: address(_remote.adapter)
        });

        vm.startBroadcast(deployerKey);

        _local.controller.updateConfig(chainIds, configs);

        // The controller is the fee payer: under `delegatecall` the router
        // takes the fee from the controller's own balance.
        if (_fundAmount > 0) {
            (bool ok,) = address(_local.controller).call{ value: _fundAmount }("");
            require(ok, "Test_Deploy: controller funding failed");
        }

        vm.stopBroadcast();
    }

    /// @dev The router serving `_chainId`, and the chain id of its counterparty
    ///      on this two-chain lane.
    function _laneFor(uint256 _chainId) internal pure returns (address router, uint256 remoteChainId) {
        if (_chainId == ARBITRUM_SEPOLIA) return (ARB_SEPOLIA_ROUTER, BASE_SEPOLIA);
        if (_chainId == BASE_SEPOLIA) return (BASE_SEPOLIA_ROUTER, ARBITRUM_SEPOLIA);

        revert("Test_Deploy: unsupported chain (use Sepolia or Base Sepolia)");
    }

    function _grant(Deployment storage _d, bytes32 _permissionId) internal {
        _d.dao.setHasPermission(address(_d.controller), deployer, _permissionId, true);
    }

    function _sendUnderGassed(Deployment storage _from, Deployment storage _to) internal {
        vm.selectFork(_from.forkId);

        // Both messages do the same amount of work (three cold SSTOREs), so the
        // ONLY difference between them is the gas limit they were sent with.
        // Whatever their outcomes differ by is therefore attributable to gas.
        uint256 goodGasLimit = vm.envOr("GOOD_GAS_LIMIT", uint256(400_000));
        uint256 badGasLimit = vm.envOr("BAD_GAS_LIMIT", uint256(90_000));

        bytes memory goodPayload = _buildPayload(address(_to.target), abi.encodeCall(CounterTarget.incrementA, ()));
        bytes memory badPayload = _buildPayload(address(_to.target), abi.encodeCall(CounterTarget.incrementB, ()));

        // Quote at the larger limit; it bounds what either send can cost.
        (address feeToken, uint256 fee, uint256 available) =
            _from.controller.quoteFee(_to.chainId, goodGasLimit, goodPayload);

        console.log("========== sending the pair ==========");
        console.log("  from chain        ", _from.chainId);
        console.log("  to chain          ", _to.chainId);
        console.log("  fee token         ", feeToken);
        console.log("  fee (wei, at good)", fee);
        console.log("  controller balance", available);
        require(available >= fee * 2, "Test_Deploy: controller underfunded for both sends");

        vm.startBroadcast(deployerKey);
        bytes32 goodTxId = _from.controller.forwardMessage(_to.chainId, goodGasLimit, goodPayload);
        bytes32 badTxId = _from.controller.forwardMessage(_to.chainId, badGasLimit, badPayload);
        vm.stopBroadcast();

        console.log("  A) incrementA, gasLimit", goodGasLimit);
        console.log("     expected: executes; count1..3 become 1");
        console.logBytes32(goodTxId);
        console.log("  B) incrementB, gasLimit", badGasLimit);
        console.log("     expected: FAILS on arrival; count4..6 stay 0");
        console.logBytes32(badTxId);
        console.log("=====================================");
        console.log("Next:");
        console.log("  1. Find both messages on https://ccip.chain.link (search the origin tx hash)");
        console.log("  2. A should show SUCCESS, B should show FAILED");
        console.log("  3. export DEST_CONTROLLER=%s", address(_to.controller));
        console.log("     export DEST_TARGET=%s", address(_to.target));
        console.log("     export TX_ID=<the txId of B, above>");
        console.log("  4. forge script ... --sig 'checkState()' --rpc-url $BASE_SEPOLIA_RPC");
        console.log("     -> state 0 means even the catch block was starved (no local recovery)");
        console.log("     -> state 1 means it recorded Delivered (retryMessage works)");
        console.log("  5. Manually execute B from the Explorer with a higher gas limit");
        console.log("  6. checkState() again -- it should now be Executed, count4..6 = 1");
    }

    /// @notice Reads what the DESTINATION controller recorded for a txId.
    /// @dev Run against the DESTINATION rpc.
    ///      ENV: DEST_CONTROLLER, TX_ID, and optionally DEST_TARGET to also
    ///      show whether the actions actually ran.
    function checkState() external view {
        CrossChainController controller = CrossChainController(payable(vm.envAddress("DEST_CONTROLLER")));
        bytes32 txId = vm.envBytes32("TX_ID");

        TransactionRecord memory record = controller.getTransaction(txId);

        console.log("chain    ", block.chainid);
        console.log("state    ", uint256(record.state));
        console.log("  0 = None      -> nothing recorded; only CCIP manual execution can recover it");
        console.log("  1 = Delivered -> recorded; retryMessage/cancelMessage available locally");
        console.log("  2 = Executed  -> ran to completion");
        console.log("  3 = Cancelled");
        console.log("bridgedAt", uint256(record.bridgedAt));

        address target = vm.envOr("DEST_TARGET", address(0));
        if (target != address(0)) {
            CounterTarget t = CounterTarget(target);
            console.log("target A counts (incrementA)", t.count1(), t.count2(), t.count3());
            console.log("target B counts (incrementB)", t.count4(), t.count5(), t.count6());
        }
    }

    /// @dev A one-action payload calling `_data` on `_target`.
    function _buildPayload(address _target, bytes memory _data) internal pure returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: _target, value: 0, data: _data });

        return abi.encode(actions);
    }

    function _report() internal view {
        console.log("========== Arbitrum Sepolia (%s) ==========", ARBITRUM_SEPOLIA);
        console.log("  DAO       ", address(arbSepolia.dao));
        console.log("  CONTROLLER", address(arbSepolia.controller));
        console.log("  EXECUTOR  ", address(arbSepolia.executor));
        console.log("  ADAPTER   ", address(arbSepolia.adapter));
        console.log("  TARGET    ", address(arbSepolia.target));

        console.log("========== Base Sepolia (%s) ==========", BASE_SEPOLIA);
        console.log("  DAO       ", address(baseSepolia.dao));
        console.log("  CONTROLLER", address(baseSepolia.controller));
        console.log("  EXECUTOR  ", address(baseSepolia.executor));
        console.log("  ADAPTER   ", address(baseSepolia.adapter));
        console.log("  TARGET    ", address(baseSepolia.target));

        console.log("Export these, then run sendUnderGassed() against $ARBITRUM_SEPOLIA_RPC:");
        console.log("  export ORIGIN_CONTROLLER=%s", address(arbSepolia.controller));
        console.log("  export DEST_CONTROLLER=%s", address(baseSepolia.controller));
        console.log("  export DEST_TARGET=%s", address(baseSepolia.target));
    }
}
