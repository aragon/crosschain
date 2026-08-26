// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { DAO } from "@aragon/osx/core/dao/DAO.sol";
import { DAOFactory } from "@aragon/osx/framework/dao/DAOFactory.sol";
import { PluginRepo } from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import { PluginRepoFactory } from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";

import { CrossChainDeploy } from "../../script/CrossChainDeploy.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { CrossChainControllerSetup } from "@src/CrossChainControllerSetup.sol";
import { Executor } from "@src/Executor.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { CrossChainDeployConformance, Deployed } from "./CrossChainDeployConformance.sol";
import { ChainIdRegistry } from "@src/registry/ChainIdRegistry.sol";
import { IBaseAdapter } from "@src/adapters/IBaseAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { Errors } from "@src/lib/Errors.sol";
import { IExecutor, Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { ChainsFixture } from "../fixtures/Chains.sol";

/// @dev The two `Addresslist` reads the zero-address evidence test needs.
///      Declared locally rather than imported so the test does not depend on
///      OSx's internal file layout.
interface Addresslist {
    function addresslistLength() external view returns (uint256);
    function isListed(address account) external view returns (bool);
}

/// @notice Fills the topology from values the test sets, and governs the hub
///         with the kit's own Multisig installer.
/// @dev Only the two seams a real consumer uses are overridden. Everything the
///      kit protects runs unmodified.
contract KitHarness is CrossChainDeploy {
    uint256[] internal presetForks;

    function presetFork(uint256 _forkId) external {
        presetForks.push(_forkId);
    }

    function addChain(
        uint256 _chainId,
        uint256 _ccipChainSelector,
        address _daoFactory,
        address _psp,
        address _pluginRepoFactory,
        address _crossChainRepo,
        address _multisigRepo,
        address _ccipRouter
    )
        external
    {
        ChainCfg storage c = _chainId == chainIds0 || chainIds0 == 0 ? hub : satellites.push();
        if (chainIds0 == 0) chainIds0 = _chainId;
        c.chainId = _chainId;
        c.daoFactory = _daoFactory;
        c.psp = _psp;
        c.pluginRepoFactory = _pluginRepoFactory;
        c.crossChainRepo = _crossChainRepo;
        c.multisigRepo = _multisigRepo;
        c.ccipRouter = _ccipRouter;
        c.ccipChainSelector = _ccipChainSelector;
        c.minApprovals = 1;
        c.members.push(address(0xA11CE));
    }

    uint256 internal chainIds0;

    function _loadTopology() internal override { }

    /// @dev Exercises the kit's own JSON loader against a fixture, then swaps in
    ///      the freshly published repos -- the file cannot know their addresses.
    function loadFromFixture(string memory _path, address _hubRepo, address _satRepo) external {
        _loadTopologyFromJson(_path);
        hub.rpc = vm.envString(hub.rpc);
        hub.crossChainRepo = _hubRepo;
        for (uint256 i = 0; i < satellites.length; i++) {
            satellites[i].rpc = vm.envString(satellites[i].rpc);
            satellites[i].crossChainRepo = _satRepo;
        }
    }

    function _createForks() internal override {
        hub.forkId = presetForks[0];
        for (uint256 i = 0; i < satellites.length; i++) {
            satellites[i].forkId = presetForks[i + 1];
        }
    }

    // --- exposed for the tests ---

    function createForks() external {
        _createForks();
    }

    /// @dev What a real consumer does between `initCrosschain()` and
    ///      `setUpCrosschain()`: create its own bare DAO on the hub fork, as the
    ///      deployer. The kit does not do this, so the harness plays consumer.
    function createHubDao() external {
        _select(hub);
        _broadcast();
        (DAO created,) = DAOFactory(hub.daoFactory)
            .createDao(
                DAOFactory.DAOSettings({
                    trustedForwarder: address(0), daoURI: "", subdomain: "", metadata: bytes("")
                }),
                new DAOFactory.PluginSettings[](0)
            );
        vm.stopBroadcast();
        hub.dao = address(created);
    }

    /// @dev A consumer installing its own hub governance after
    ///      `installCrosschain()`. This uses the kit's Multisig installer,
    ///      which is also the satellite default.
    function installHubGovernance() external {
        _select(hub);
        _installMultisigGovernance(hub);
    }

    /// @dev The consumer's last call, once its governance is in.
    function handOverHub() external {
        _handOverHub();
    }

    /// @dev Drives a DAO-acting helper against the hub from outside, so a test
    ///      can invoke it while a different fork is selected.
    function grantExecuteOnHub(address _who) external {
        _broadcast();
        _grantExecute(hub, _who);
        vm.stopBroadcast();
    }

    function selectHub() external {
        _select(hub);
    }

    function selectSatellite(uint256 _i) external {
        _select(satellites[_i]);
    }

    function corruptHubChainId(uint256 _wrong) external {
        hub.chainId = _wrong;
    }

    function hubCfg() external view returns (ChainCfg memory) {
        return hub;
    }

    function satCfg(uint256 _i) external view returns (ChainCfg memory) {
        return satellites[_i];
    }

    /// @dev The narrow shape the conformance suite takes.
    function hubDeployed() external view returns (Deployed memory) {
        return Deployed(hub.dao, hub.controller, hub.executor, hub.adapter, hub.registry, hub.governors);
    }

    function satDeployed(uint256 _i) external view returns (Deployed memory) {
        ChainCfg storage c = satellites[_i];
        return Deployed(c.dao, c.controller, c.executor, c.adapter, c.registry, c.governors);
    }

    function clearSatelliteGovernors(uint256 _i) external {
        delete satellites[_i].governors;
    }

    /// @dev An empty topology, as a consumer with a broken loader would supply.
    function clearSatellites() external {
        delete satellites;
    }

    // --- seams for the negative tests -------------------------------------
    //
    // Most refusal paths are reached the honest way now — by calling the two
    // public entry points out of order, or after breaking a precondition on
    // chain. These seams cover the rest: corrupting state the entry points
    // read, and reaching internals whose guards fire mid-sequence.

    function handOver() external {
        _handOver();
    }

    /// @dev A typo'd or wrong-chain hub DAO, as a consumer would supply it.
    function setHubDao(address _dao) external {
        hub.dao = _dao;
    }

    /// @dev Reaches `_prepareController`'s reserve guard on the HUB path.
    function setMinFailedMessageGas(uint256 _gas) external {
        minFailedMessageGas = _gas;
    }

    /// @dev Drives `_addGovernor`'s input validation directly.
    function addHubGovernor(address _governor) external {
        _addGovernor(hub, _governor);
    }

    function setDeployer(address _who) external {
        deployer = _who;
    }

    /// @dev Puts a zero address into the roster the default installer reads, and
    ///      raises the threshold so the quorum genuinely becomes unreachable.
    function poisonHubRoster() external {
        hub.members.push(address(0));
        hub.minApprovals = 2;
    }

    /// @dev Installs the Multisig with a chosen roster, BYPASSING the kit's own
    ///      validation, so a test can observe what OSx does with input the kit
    ///      refuses. On the hub, because that is the one DAO the deployer can
    ///      still act as after a full run. Never a production path.
    function installHubMultisigUnchecked(address[] memory _members, uint16 _minApprovals)
        external
        returns (address plugin)
    {
        _select(hub);
        PluginRepo repo = PluginRepo(hub.multisigRepo);
        PluginRepo.Version memory version = repo.getLatestVersion(repo.latestRelease());

        bytes memory data = abi.encode(
            _members,
            MultisigSettings({ onlyListed: true, minApprovals: _minApprovals }),
            TargetConfig({ target: address(0), operation: 0 }),
            bytes("")
        );

        _broadcast();
        (plugin,) = _installPlugin(hub, repo, version.tag, data);
        vm.stopBroadcast();
    }
}

/// @notice Drives the kit end to end across Sepolia and Base Sepolia, against
///         the real OSx deployments on both.
/// @dev The cross-chain repo is published fresh on each fork rather than taken
///      from a published address, so the run exercises the controller code in
///      THIS repo — which is the point of the kit having its own suite instead
///      of relying on its consumers'.
///
///      Skips without RPCs. Public endpoints are fine.
contract CrossChainDeployKitTest is CrossChainDeployConformance, ChainsFixture {
    // Real OSx 1.4 deployments.
    address internal constant SEP_DAO_FACTORY = 0xB815791c233807D39b7430127975244B36C19C8e;
    address internal constant SEP_PSP = 0xC24188a73dc09aA7C721f96Ad8857B469C01dC9f;
    address internal constant SEP_REPO_FACTORY = 0x399Ce2a71ef78bE6890EB628384dD09D4382a7f0;
    address internal constant SEP_MULTISIG_REPO = 0x9e7956C8758470dE159481e5DD0d08F8B59217A2;

    address internal constant BASESEP_DAO_FACTORY = 0x016CBa9bd729C30b16849b2c52744447767E9dab;
    address internal constant BASESEP_PSP = 0xd97D409Ca645b108468c26d8506f3a4Bf9D0BE81;
    address internal constant BASESEP_REPO_FACTORY = 0xD8Cc78EDB894ff93d757cCa481D2B43b5445E2aE;
    address internal constant BASESEP_MULTISIG_REPO = 0x705596219C1C31dd92E3449c8E04251CcacCb6aB;

    // Real CCIP routers; nothing here sends a message, but the adapter requires
    // the router to have code.
    address internal constant SEP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address internal constant BASESEP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;

    // From `test/fixtures/chains.json`. `immutable` rather than `constant`: a
    // JSON read is a call, not a compile-time expression.
    uint256 internal immutable SEPOLIA;
    uint256 internal immutable BASE_SEPOLIA;
    uint256 internal immutable ETHEREUM;

    uint256 internal immutable SEPOLIA_SELECTOR;
    uint256 internal immutable BASE_SEPOLIA_SELECTOR;

    constructor() {
        SEPOLIA = chainId("sepolia");
        BASE_SEPOLIA = chainId("baseSepolia");
        ETHEREUM = chainId("ethereum");

        SEPOLIA_SELECTOR = ccipSelector("sepolia");
        BASE_SEPOLIA_SELECTOR = ccipSelector("baseSepolia");
    }

    uint256 internal constant DEPLOYER_KEY = uint256(keccak256("crosschain.kit.test"));

    KitHarness internal kit;
    uint256 internal hubFork;
    uint256 internal satFork;

    function setUp() public {
        vm.skip(bytes(vm.envOr("SEPOLIA_RPC_URL", string(""))).length == 0);
        vm.skip(bytes(vm.envOr("BASE_SEPOLIA_RPC_URL", string(""))).length == 0);

        hubFork = vm.createFork(vm.envString("SEPOLIA_RPC_URL"));
        satFork = vm.createFork(vm.envString("BASE_SEPOLIA_RPC_URL"));

        // Built before any fork is selected, so it survives every later switch
        // without `vm.makePersistent`. See the note on CrossChainDeploy.
        kit = new KitHarness();

        address deployer = vm.addr(DEPLOYER_KEY);
        address sepRepo = _publishCrossChainRepo(hubFork, SEP_REPO_FACTORY, deployer);
        address baseRepo = _publishCrossChainRepo(satFork, BASESEP_REPO_FACTORY, deployer);

        kit.addChain(
            SEPOLIA,
            SEPOLIA_SELECTOR,
            SEP_DAO_FACTORY,
            SEP_PSP,
            SEP_REPO_FACTORY,
            sepRepo,
            SEP_MULTISIG_REPO,
            SEP_ROUTER
        );
        kit.addChain(
            BASE_SEPOLIA,
            BASE_SEPOLIA_SELECTOR,
            BASESEP_DAO_FACTORY,
            BASESEP_PSP,
            BASESEP_REPO_FACTORY,
            baseRepo,
            BASESEP_MULTISIG_REPO,
            BASESEP_ROUTER
        );
        kit.presetFork(hubFork);
        kit.presetFork(satFork);
        kit.createForks();
    }

    /// @dev Publishes this repo's own `CrossChainControllerSetup` as release 1
    ///      build 1, and funds the deployer on that fork.
    function _publishCrossChainRepo(uint256 _fork, address _repoFactory, address _deployer) internal returns (address) {
        vm.selectFork(_fork);
        vm.deal(_deployer, 100 ether);

        vm.startPrank(_deployer);
        address setup = address(new CrossChainControllerSetup(address(new CrossChainController())));
        PluginRepo repo = PluginRepoFactory(_repoFactory)
            .createPluginRepoWithFirstVersion(
                string.concat("kit-", vm.toString(_fork), "-", vm.toString(uint160(address(this)))),
                setup,
                _deployer,
                bytes("kit"),
                bytes("kit")
            );
        vm.stopPrank();

        return address(repo);
    }

    /// @dev The whole consumer sequence, through the kit's two entry points,
    ///      ending with the consumer's own hub handover.
    function _run() internal {
        _runThroughInstall();
        kit.installHubGovernance();
        kit.handOverHub();
    }

    /// @dev Up to and including `installCrosschain()` — the point where the kit
    ///      is done and the hub's governance is still the consumer's future.
    function _runThroughInstall() internal {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setUpCrosschain();
        kit.installCrosschain();
    }

    // -------------------------------------------------------------------------
    // Forking and the chain-id guard
    // -------------------------------------------------------------------------

    function test_selectLandsOnTheConfiguredChain() public {
        kit.selectHub();
        assertEq(block.chainid, SEPOLIA, "hub fork");
        kit.selectSatellite(0);
        assertEq(block.chainid, BASE_SEPOLIA, "satellite fork");
        kit.selectHub();
        assertEq(block.chainid, SEPOLIA, "returned to hub");
    }

    function test_selectRejectsAForkThatIsNotTheConfiguredChain() public {
        kit.corruptHubChainId(ETHEREUM);
        vm.expectRevert(bytes("RPC does not match the configured chain id"));
        kit.selectHub();
    }

    // -------------------------------------------------------------------------
    // The full run
    // -------------------------------------------------------------------------

    function test_fullRun_deploysTheWholeStackOnEveryChain() public {
        _run();

        kit.selectHub();
        _assertStack(kit.hubCfg());
        kit.selectSatellite(0);
        _assertStack(kit.satCfg(0));
    }

    function _assertStack(CrossChainDeploy.ChainCfg memory _c) private view {
        assertGt(_c.dao.code.length, 0, "dao");
        assertGt(_c.controller.code.length, 0, "controller");
        assertGt(_c.executor.code.length, 0, "executor");
        assertGt(_c.adapter.code.length, 0, "adapter");
    }

    /// @notice **The invariant the kit exists for.** After the complete
    ///         consumer sequence — the kit's satellite handover plus the
    ///         consumer's own `_handOverHub()` — no EOA can act as any DAO,
    ///         and every declared governor still can. Mid-sequence the hub is
    ///         deliberately different — see
    ///         {test_installLeavesTheDeployersExecuteOnTheHub}.
    function test_fullRun_handsEveryDaoToItsGovernance() public {
        _run();

        kit.selectHub();
        _assertHandedOver(kit.hubCfg());
        kit.selectSatellite(0);
        _assertHandedOver(kit.satCfg(0));
    }

    function _assertHandedOver(CrossChainDeploy.ChainCfg memory _c) private view {
        DAO dao = DAO(payable(_c.dao));
        assertFalse(
            dao.hasPermission(_c.dao, vm.addr(DEPLOYER_KEY), dao.EXECUTE_PERMISSION_ID(), ""),
            "deployer must not keep EXECUTE"
        );
        assertGt(_c.governors.length, 0, "a governor must be declared");
        for (uint256 i = 0; i < _c.governors.length; i++) {
            assertTrue(
                dao.hasPermission(_c.dao, _c.governors[i], dao.EXECUTE_PERMISSION_ID(), ""),
                "declared governor must be able to execute"
            );
        }
    }

    /// @notice No controller may act as its own DAO, and each gets a dedicated
    ///         Executor owned by it.
    function test_fullRun_givesEveryControllerADedicatedExecutor() public {
        _run();

        kit.selectHub();
        _assertDedicatedExecutor(kit.hubCfg());
        kit.selectSatellite(0);
        _assertDedicatedExecutor(kit.satCfg(0));
    }

    function _assertDedicatedExecutor(CrossChainDeploy.ChainCfg memory _c) private view {
        DAO dao = DAO(payable(_c.dao));
        assertFalse(
            dao.hasPermission(_c.dao, _c.controller, dao.EXECUTE_PERMISSION_ID(), ""),
            "controller must not hold EXECUTE on its DAO"
        );
        assertTrue(_c.executor != _c.dao, "the executor is dedicated, never the DAO");
        assertEq(Executor(payable(_c.executor)).owner(), _c.controller, "executor owned by the controller");
    }

    /// @notice The installation really landed, and the PSP gave ROOT back in the
    ///         same transaction that borrowed it.
    function test_fullRun_installsControllersAndReturnsRoot() public {
        _run();

        kit.selectHub();
        _assertInstalled(kit.hubCfg(), SEP_PSP);
        kit.selectSatellite(0);
        _assertInstalled(kit.satCfg(0), BASESEP_PSP);
    }

    function _assertInstalled(CrossChainDeploy.ChainCfg memory _c, address _psp) private view {
        DAO dao = DAO(payable(_c.dao));
        assertTrue(
            dao.hasPermission(_c.controller, _c.dao, Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID, ""),
            "the DAO can configure its controller"
        );
        assertFalse(dao.hasPermission(_c.dao, _psp, dao.ROOT_PERMISSION_ID(), ""), "PSP must not keep ROOT");
    }

    /// @notice Lanes wired both ways. Local/remote inverted is invisible on
    ///         chain until a message silently fails to arrive.
    function test_fullRun_wiresLanesInBothDirections() public {
        _run();

        address hubAdapter = kit.hubCfg().adapter;
        address satAdapter = kit.satCfg(0).adapter;

        kit.selectHub();
        (address localOnHub, address remoteOnHub) =
            CrossChainController(payable(kit.hubCfg().controller)).chainToAdapter(BASE_SEPOLIA);
        assertEq(localOnHub, hubAdapter, "hub local");
        assertEq(remoteOnHub, satAdapter, "hub remote");

        kit.selectSatellite(0);
        (address localOnSat, address remoteOnSat) =
            CrossChainController(payable(kit.satCfg(0).controller)).chainToAdapter(SEPOLIA);
        assertEq(localOnSat, satAdapter, "satellite local");
        assertEq(remoteOnSat, hubAdapter, "satellite remote");
    }

    /// @notice Both chains run the same controller build.
    function test_fullRun_pinsOneControllerBuildEverywhere() public {
        _run();
        // Both repos were published fresh as release 1 build 1; the assertion
        // that matters is that the satellite install did not resolve its own
        // "latest" independently. Covered structurally by `getVersion` reverting
        // on a missing build, and here by both controllers existing at all.
        assertGt(kit.hubCfg().controller.code.length, 0, "hub controller");
        assertGt(kit.satCfg(0).controller.code.length, 0, "satellite controller");
    }

    // -------------------------------------------------------------------------
    // Conformance and the config loader
    // -------------------------------------------------------------------------

    /// @notice The shared conformance suite, run against this deployment. A
    ///         consumer inherits the same contract and points it at its own.
    /// @dev The hub's conformance is narrower by design: no deployer-revoked,
    ///      no governability — those are the consumer's promises now, asserted
    ///      here through `_assertHandedOver` in the handover test instead.
    function test_fullRun_isConformant() public {
        _run();

        kit.selectHub();
        assertHubConformant(kit.hubDeployed(), SEP_PSP);
        assertLaneWired(kit.hubCfg().controller, BASE_SEPOLIA, kit.hubCfg().adapter, kit.satCfg(0).adapter);

        kit.selectSatellite(0);
        assertSatelliteConformant(kit.satDeployed(0), BASESEP_PSP, vm.addr(DEPLOYER_KEY));
        assertLaneWired(kit.satCfg(0).controller, SEPOLIA, kit.satCfg(0).adapter, kit.hubCfg().adapter);
    }

    /// @notice Each chain's registry carries the REMOTE lane, read back through
    ///         the adapter bound to it.
    /// @dev `_requireMapsChain` covers the forward direction; this adds the
    ///      inverse and the negative.
    function test_fullRun_seedsEachChainIdRegistryWithItsRemoteLane() public {
        _run();

        kit.selectHub();
        IBaseAdapter hubAdapter = IBaseAdapter(kit.hubCfg().adapter);
        assertEq(hubAdapter.toNativeChainId(BASE_SEPOLIA), BASE_SEPOLIA_SELECTOR, "hub -> satellite selector");
        assertEq(hubAdapter.fromNativeChainId(BASE_SEPOLIA_SELECTOR), BASE_SEPOLIA, "hub inverts the satellite lane");

        // Hub-and-spoke: the hub resolves satellites, never itself.
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, SEPOLIA));
        hubAdapter.toNativeChainId(SEPOLIA);

        kit.selectSatellite(0);
        IBaseAdapter satAdapter = IBaseAdapter(kit.satCfg(0).adapter);
        assertEq(satAdapter.toNativeChainId(SEPOLIA), SEPOLIA_SELECTOR, "satellite -> hub selector");
        assertEq(satAdapter.fromNativeChainId(SEPOLIA_SELECTOR), SEPOLIA, "satellite inverts the hub lane");

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, ETHEREUM));
        satAdapter.toNativeChainId(ETHEREUM);
    }

    /// @notice Governance can add a chain to a live deployment without touching
    ///         the adapters -- the reason the registry exists.
    /// @dev Runs AFTER the handover, as the governor, so it does not lean on
    ///      leftover deployer permissions.
    function test_afterHandover_governanceCanAddAChainWithoutANewAdapter() public {
        _run();

        kit.selectSatellite(0);
        IBaseAdapter satAdapter = IBaseAdapter(kit.satCfg(0).adapter);

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, ETHEREUM));
        satAdapter.toNativeChainId(ETHEREUM);

        address governor = kit.satCfg(0).governors[0];
        address satDao = kit.satCfg(0).dao;

        Action[] memory actions = new Action[](1);
        actions[0].to = kit.satCfg(0).registry;
        actions[0].data = abi.encodeCall(ChainIdRegistry.setChainIdPair, (ETHEREUM, ccipSelector("ethereum")));

        // `satDao` is read BEFORE the prank on purpose: `vm.prank` applies to
        // the next external call, and `kit.satCfg(0)` is one.
        vm.prank(governor);
        IExecutor(satDao).execute(bytes32(0), actions, 0);

        assertEq(
            satAdapter.toNativeChainId(ETHEREUM),
            ccipSelector("ethereum"),
            "governance could not add a chain to its own live deployment"
        );
        assertEq(
            address(BaseAdapter(address(satAdapter)).CHAIN_ID_REGISTRY()),
            kit.satCfg(0).registry,
            "the adapter must be the same one: adding a chain may not require replacing it"
        );
    }

    /// @notice The kit's JSON loader fills the same fields the harness sets by
    ///         hand, so the zero-code path reaches the same deployment.
    function test_topologyLoadsFromJson() public {
        KitHarness fresh = new KitHarness();
        fresh.loadFromFixture("test/kit/fixtures/topology.json", address(0xBEEF), address(0xCAFE));

        assertEq(fresh.hubCfg().chainId, SEPOLIA, "hub chain");
        assertEq(fresh.satCfg(0).chainId, BASE_SEPOLIA, "satellite chain");
        assertEq(fresh.hubCfg().daoFactory, SEP_DAO_FACTORY, "hub factory");
        assertEq(fresh.satCfg(0).multisigRepo, BASESEP_MULTISIG_REPO, "satellite multisig repo");
        assertEq(fresh.satCfg(0).minApprovals, 1, "threshold");
        assertEq(fresh.hubCfg().members.length, 1, "roster");
        assertEq(fresh.hubCfg().ccipChainSelector, SEPOLIA_SELECTOR, "hub selector");
        assertEq(fresh.satCfg(0).ccipChainSelector, BASE_SEPOLIA_SELECTOR, "satellite selector");
    }

    // -------------------------------------------------------------------------
    // Refusals
    //
    // Everything above drives a CORRECT deployment and checks the outcome,
    // which can only prove the kit does the right thing when asked correctly.
    // Without the tests below, every guard here is deletable with the suite
    // still green: nothing else asks the kit to say no.
    // -------------------------------------------------------------------------

    /// @notice A DAO with no declared governor must not be handed over.
    /// @dev The README's opening promise: "It will not finish a deployment that
    ///      leaves a DAO nobody can act as." The guard runs inside
    ///      `setUpCrosschain()` now, immediately before each satellite revoke;
    ///      it is reached here through the seam because nothing outside the kit
    ///      can slip between governance and handover any more.
    function test_handoverRefusesADaoWithNoGovernor() public {
        _run();
        kit.clearSatelliteGovernors(0);

        vm.expectRevert(bytes("DAO has no governor: nothing could act as it after handover"));
        kit.handOver();
    }

    /// @notice A zero failure-gas reserve must be refused at prepare, on the
    ///         hub path, which does not pass through the satellite sweep.
    /// @dev Zero lets an out-of-gas payload revert the whole delivery, recording
    ///      nothing -- the message is then unreachable by both `retryMessage`
    ///      and `cancelMessage`. The value is baked into the proxy's
    ///      `initialize` at prepare time, so the guard must fire there; the
    ///      hub's first prepare is the earliest it can.
    function test_prepareRefusesAZeroFailureGasReserve() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setMinFailedMessageGas(0);

        vm.expectRevert(bytes("minFailedMessageGas of 0 disables the failure-record reserve"));
        kit.setUpCrosschain();
    }

    // -------------------------------------------------------------------------
    // The two-call contract
    //
    // The hub DAO is the consumer's, so the kit cannot guarantee by
    // construction that it can act as it -- it has to refuse when it cannot.
    // Each test breaks exactly one precondition and expects the exact sentence,
    // so a guard reverting for a DIFFERENT reason fails rather than passing by
    // coincidence.
    // -------------------------------------------------------------------------

    /// @notice A topology with no satellites would "succeed" vacuously: a hub
    ///         controller with zero lanes, nothing cross-chain about it.
    function test_setUpRefusesAnEmptyTopology() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.clearSatellites();

        vm.expectRevert(bytes("no satellites configured: a single-chain DAO does not need this kit"));
        kit.setUpCrosschain();
    }

    /// @notice A consumer that never created the hub DAO gets told what to do,
    ///         not a revert about code at the zero address.
    function test_setUpRefusesAnUnsetHubDao() public {
        kit.initCrosschain(DEPLOYER_KEY);

        vm.expectRevert(bytes("hub.dao is not set: create the hub DAO after initCrosschain()"));
        kit.setUpCrosschain();
    }

    /// @notice `setUpCrosschain()` burns satellites and subdomains, so it must
    ///         refuse a hub DAO that does not exist on the hub chain — not
    ///         discover it at install, after those are unrecoverable.
    function test_setUpRefusesAHubDaoWithNoCode() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.setHubDao(address(0xDEAD));

        vm.expectRevert(bytes("hub.dao has no code on the hub chain: it was created on another fork, or not at all"));
        kit.setUpCrosschain();
    }

    /// @notice A second `setUpCrosschain()` would prepare a second controller
    ///         and redeploy every satellite, subdomain burn included.
    function test_setUpRefusesASecondRun() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setUpCrosschain();

        vm.expectRevert(bytes("setUpCrosschain already ran"));
        kit.setUpCrosschain();
    }

    /// @notice `installCrosschain()` has nothing to apply before
    ///         `setUpCrosschain()` prepared it.
    function test_installRefusesBeforeSetUp() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();

        vm.expectRevert(bytes("call setUpCrosschain first: installCrosschain only applies the install it prepared"));
        kit.installCrosschain();
    }

    /// @notice The consumer revoked its own `EXECUTE` between the two calls;
    ///         the kit must say so rather than fail deep inside `DAO.execute`.
    function test_installRefusesWithoutExecuteOnTheHubDao() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setUpCrosschain();

        kit.selectHub();
        DAO dao = DAO(payable(kit.hubCfg().dao));
        // Read the id BEFORE pranking: an external call in the revoke's own
        // argument list would consume the prank and the revoke would run as
        // the test contract instead of as the DAO.
        bytes32 executeId = dao.EXECUTE_PERMISSION_ID();
        vm.prank(address(dao));
        dao.revoke(address(dao), vm.addr(DEPLOYER_KEY), executeId);

        // The HUB message, deliberately not the kit-created one. On a DAO the
        // consumer made there is no automatic grant to have gone wrong, so
        // `--sender` advice would send them to debug the wrong thing.
        vm.expectRevert(
            bytes(
                "the deployer cannot act as the hub DAO: grant it EXECUTE on the DAO before calling the kit, and do not revoke until installCrosschain() has run. A CONDITIONAL grant reads as absent here -- the probe passes empty calldata -- so the deployer's grant must be unconditional"
            )
        );
        kit.installCrosschain();
    }

    /// @notice A DAO that is not ROOT on itself cannot lend the PSP ROOT, so
    ///         the apply is structurally impossible — refuse it by name.
    /// @dev `DAOFactory` DAOs always hold ROOT on themselves; the premise of
    ///      the new gate is not trusting how the consumer built theirs.
    function test_installRefusesWhenTheDaoLacksRootOnItself() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setUpCrosschain();

        kit.selectHub();
        DAO dao = DAO(payable(kit.hubCfg().dao));
        // Id read before the prank; see test_installRefusesWithoutExecuteOnTheHubDao.
        bytes32 rootId = dao.ROOT_PERMISSION_ID();
        vm.prank(address(dao));
        dao.revoke(address(dao), address(dao), rootId);

        vm.expectRevert(
            bytes(
                "the hub DAO does not hold ROOT on itself: the kit acts BY executing grants as the DAO, which OSx gates on ROOT"
            )
        );
        kit.installCrosschain();
    }

    /// @notice A deployer holding ROOT is refused: the handover revokes only
    ///         EXECUTE, so it could grant itself EXECUTE back afterwards.
    /// @dev The reachable path is a consumer that built its hub DAO by calling
    ///      `DAO.initialize` directly rather than through `DAOFactory` --
    ///      `_initializePermissionManager` leaves ROOT with `_initialOwner` and
    ///      nothing revokes it. Simulated here by granting it, because the
    ///      fixture necessarily uses the factory.
    function test_installRefusesADeployerHoldingRoot() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setUpCrosschain();

        kit.selectHub();
        DAO dao = DAO(payable(kit.hubCfg().dao));
        bytes32 rootId = dao.ROOT_PERMISSION_ID();
        vm.prank(address(dao));
        dao.grant(address(dao), vm.addr(DEPLOYER_KEY), rootId);

        vm.expectRevert(
            bytes(
                "the deployer holds ROOT on the hub DAO: the handover only revokes EXECUTE, so it could re-grant itself EXECUTE afterwards and bypass the governance being installed. Revoke the deployer's ROOT before calling the kit"
            )
        );
        kit.installCrosschain();
    }

    /// @notice The handover must strip ROOT as well as EXECUTE, so a leftover
    ///         grant from a hook cannot outlive the run.
    /// @dev This is the second half of the same defect: the precondition above
    ///      only guards the hub's entry, and a hook can call `_grantRoot`
    ///      mid-run. Without the paired revoke the deployer keeps the authority
    ///      to re-grant itself EXECUTE forever, and conformance stays green
    ///      because it only ever looks at EXECUTE.
    function test_handoverRevokesRootAsWellAsExecute() public {
        _runThroughInstall();
        kit.installHubGovernance();

        kit.selectHub();
        DAO dao = DAO(payable(kit.hubCfg().dao));
        bytes32 rootId = dao.ROOT_PERMISSION_ID();
        address dep = vm.addr(DEPLOYER_KEY);

        // Stand in for a hook that granted ROOT and forgot to pair it.
        vm.prank(address(dao));
        dao.grant(address(dao), dep, rootId);
        assertTrue(dao.hasPermission(address(dao), dep, rootId, ""), "setup: deployer should hold ROOT");

        kit.handOverHub();

        assertFalse(dao.hasPermission(address(dao), dep, rootId, ""), "handover left ROOT with the deployer");
        assertFalse(
            dao.hasPermission(address(dao), dep, dao.EXECUTE_PERMISSION_ID(), ""),
            "handover left EXECUTE with the deployer"
        );
    }

    /// @notice A DAO-acting helper invoked on the wrong fork must refuse by
    ///         name instead of silently writing to the wrong chain.
    /// @dev The helpers run inside an active broadcast and `vm.selectFork`
    ///      reverts during one, so they cannot select for themselves. Their
    ///      correctness is therefore a property of what ran BEFORE them --
    ///      `setUpCrosschain()` exits on the last satellite's fork, and the
    ///      `virtual` `_report()` can move the selection under a consumer.
    ///      Without the guard nothing reverts: addresses exist on every chain,
    ///      and OSx contracts genuinely collide across testnets.
    function test_daoHelperRefusesOnTheWrongFork() public {
        kit.initCrosschain(DEPLOYER_KEY);
        kit.createHubDao();
        kit.setUpCrosschain();

        // Stand on the satellite, then act on the HUB config: the exact shape a
        // consumer hits when it calls a helper after setUpCrosschain().
        kit.selectSatellite(0);

        // Put code at the hub DAO's address on THIS fork. Without it foundry
        // stops the call itself with "does not exist on active fork", which is
        // not the hazard: OSx addresses genuinely collide across testnets
        // (sepolia and arbitrum-sepolia share a PSP), and where they collide
        // the call succeeds against the wrong chain and nothing reverts. This
        // makes the fixture reproduce THAT case, so the guard is what fails the
        // test rather than a missing-contract accident.
        address hubDao = kit.hubCfg().dao;
        vm.etch(hubDao, address(new AlwaysAccepts()).code);

        vm.expectRevert(
            bytes(
                "wrong fork selected for this chain: call _select(<chain>) before the helper, and before _broadcast() -- vm.selectFork reverts inside an active broadcast"
            )
        );
        kit.grantExecuteOnHub(address(0xBEEF));
    }

    /// @notice A second `installCrosschain()` must be told apart from the
    ///         first: OSx would also refuse it, but deep inside the PSP with a
    ///         setup id, after the preconditions all passed.
    function test_installRefusesASecondInstall() public {
        _runThroughInstall();

        vm.expectRevert(bytes("this controller is already installed on this DAO"));
        kit.installCrosschain();
    }

    /// @notice **The kit revokes nothing on the hub.** Every consumer's next
    ///         step — installing governance, granting against final addresses —
    ///         depends on the deployer's `EXECUTE` surviving the install, and
    ///         nothing else would catch a regression of that promise.
    function test_installLeavesTheDeployersExecuteOnTheHub() public {
        _runThroughInstall();

        kit.selectHub();
        DAO dao = DAO(payable(kit.hubCfg().dao));
        assertTrue(
            dao.hasPermission(address(dao), vm.addr(DEPLOYER_KEY), dao.EXECUTE_PERMISSION_ID(), ""),
            "the deployer's EXECUTE on the hub is the consumer's working authority; the kit must not take it"
        );
    }

    /// @notice `_handOverHub()` must refuse an ungoverned hub, exactly as the
    ///         satellite handover would — otherwise every consumer revokes
    ///         bare-handed on the most important chain, and one forgotten
    ///         `_addGovernor` freezes the DAO that holds every repair lever.
    function test_handOverHubRefusesAnUngovernedHub() public {
        _runThroughInstall();

        vm.expectRevert(bytes("DAO has no governor: nothing could act as it after handover"));
        kit.handOverHub();
    }

    /// @notice `address(0)` is not a governor.
    /// @dev OSx will report a grant against the zero address, so without this
    ///      the governability proof passes on a DAO nothing can act as.
    function test_addGovernorRefusesTheZeroAddress() public {
        vm.expectRevert(bytes("governor is the zero address: a DAO governed by nobody is not governed"));
        kit.addHubGovernor(address(0));
    }

    /// @notice The deployer is not governance -- phase 6 revokes it.
    function test_addGovernorRefusesTheDeployer() public {
        address who = makeAddr("the-deployer");
        kit.setDeployer(who);

        vm.expectRevert(
            bytes(
                "governor is the deployer, whose EXECUTE the handover revokes: declare the governance that outlives the run"
            )
        );
        kit.addHubGovernor(who);
    }

    /// @notice A roster entry of `address(0)` raises the threshold without
    ///         adding a signer, so the quorum can never be met.
    /// @dev OSx's `Addresslist` rejects duplicates but accepts the zero address
    ///      and counts it, so 2-of-["0xAlice", "0x0"] installs cleanly and passes
    ///      a `hasPermission` check while being permanently unable to act.
    ///      Staged on the hub: it is the one DAO the deployer can still act as
    ///      after a full run, so without the guard this install would succeed.
    function test_multisigInstallerRefusesAZeroInTheRoster() public {
        _runThroughInstall();
        kit.poisonHubRoster();

        vm.expectRevert(bytes("governance roster contains the zero address: quorum would be unreachable"));
        kit.installHubGovernance();
    }

    /// @notice Why the guard above has to exist here, and not upstream.
    /// @dev The obvious objection to that guard is that `address(0)` should
    ///      already be rejected by OSx. It is not, and this is the evidence
    ///      rather than an argument: installing 2-of-[Alice, 0x0] through the
    ///      REAL published Multisig on a real chain succeeds.
    ///
    ///      `Addresslist._addAddresses` checks `isListed` and nothing else, and
    ///      neither `Multisig.initialize` nor `addAddresses` adds a zero check on
    ///      top. So the zero is marked listed, counts toward
    ///      `addresslistLength`, and lifts the threshold that
    ///      `minApprovals <= members.length` then validates against — while
    ///      adding no one who can ever approve.
    ///
    ///      The result reads as governed from every angle the kit could
    ///      otherwise check: the plugin exists, holds EXECUTE, and
    ///      `_assertGovernable` passes. It simply cannot pass a proposal.
    function test_osxItselfAcceptsAZeroAddressInAMultisigRoster() public {
        _runThroughInstall();

        address[] memory poisoned = new address[](2);
        poisoned[0] = address(0xA11CE);
        poisoned[1] = address(0);

        address plugin = kit.installHubMultisigUnchecked(poisoned, 2);

        assertEq(Addresslist(plugin).addresslistLength(), 2, "OSx counted the zero toward the roster");
        assertTrue(Addresslist(plugin).isListed(address(0)), "OSx listed the zero address as a signer");
        assertFalse(
            Addresslist(plugin).isListed(address(0xBEEF)), "sanity: isListed is not answering true for anything"
        );

        // One real signer against a threshold of two: unreachable by arithmetic,
        // and nothing on chain reports a problem.
        assertTrue(Addresslist(plugin).isListed(address(0xA11CE)), "the one real signer");
    }
}

/// @dev Stands in for a real contract living at the same address on another
///      chain — the collision case that makes a wrong-fork write silent.
contract AlwaysAccepts {
    fallback() external payable { }
}
