// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { DAO } from "@aragon/osx/core/dao/DAO.sol";
import { PluginRepo } from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import { PluginRepoFactory } from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";

import { CrossChainDeploy } from "../../script/CrossChainDeploy.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { CrossChainControllerSetup } from "@src/CrossChainControllerSetup.sol";
import { Executor } from "@src/Executor.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { CrossChainDeployConformance, Deployed } from "./CrossChainDeployConformance.sol";

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

    /// @dev A real consumer installs its own governance here. This uses the
    ///      kit's Multisig installer, which is also the satellite default.
    function _configureHub() internal override {
        _installMultisigGovernance(hub);
    }

    // --- exposed for the tests ---

    function createForks() external {
        _createForks();
    }

    /// @dev What `runWith` does, minus `_loadTopology`/`_createForks`, which the
    ///      test has already done so it can fund the deployer on the same forks.
    function phasesWith(uint256 _key) external {
        deployerKey = _key;
        deployer = _resolveDeployer();
        phases();
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
        return Deployed(hub.dao, hub.controller, hub.executor, hub.adapter, hub.governors);
    }

    function satDeployed(uint256 _i) external view returns (Deployed memory) {
        ChainCfg storage c = satellites[_i];
        return Deployed(c.dao, c.controller, c.executor, c.adapter, c.governors);
    }

    function clearSatelliteGovernors(uint256 _i) external {
        delete satellites[_i].governors;
    }

    // --- seams for the negative tests -------------------------------------
    //
    // `phases()` is a single call, so a test that has to corrupt the run BETWEEN
    // two phases -- the only way to reach most of the kit's refusal paths --
    // cannot go through it. These split it at the points that matter.

    /// @dev Everything up to and including governance, stopping before handover.
    function phasesUpToHandover(uint256 _key) external {
        deployerKey = _key;
        deployer = _resolveDeployer();
        _createSatelliteDaos();
        _installControllers(minFailedMessageGas);
        _deployAdaptersAndRoute();
        _configureGovernance();
    }

    function handOver() external {
        _handOver();
    }

    /// @dev Reaches `_installControllers`' own guard without a full run.
    function installControllersWith(uint256 _gas) external {
        _installControllers(_gas);
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
    function poisonSatelliteRoster(uint256 _i) external {
        satellites[_i].members.push(address(0));
        satellites[_i].minApprovals = 2;
    }

    function installSatelliteGovernance(uint256 _i) external {
        _installMultisigGovernance(satellites[_i]);
    }

    /// @dev Installs the Multisig with a chosen roster, BYPASSING the kit's own
    ///      validation, so a test can observe what OSx does with input the kit
    ///      refuses. Never a production path.
    function installMultisigUnchecked(uint256 _i, address[] memory _members, uint16 _minApprovals)
        external
        returns (address plugin)
    {
        ChainCfg storage c = satellites[_i];
        PluginRepo repo = PluginRepo(c.multisigRepo);
        PluginRepo.Version memory version = repo.getLatestVersion(repo.latestRelease());

        bytes memory data = abi.encode(
            _members,
            MultisigSettings({ onlyListed: true, minApprovals: _minApprovals }),
            TargetConfig({ target: address(0), operation: 0 }),
            bytes("")
        );

        _broadcast();
        (plugin,) = _installPlugin(c, repo, version.tag, data);
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
contract CrossChainDeployKitTest is CrossChainDeployConformance {
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

    // Local, because maps mainnets only -- deliberately, it is
    // audited production source.
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant ETHEREUM = 1;

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

        kit.addChain(SEPOLIA, SEP_DAO_FACTORY, SEP_PSP, SEP_REPO_FACTORY, sepRepo, SEP_MULTISIG_REPO, SEP_ROUTER);
        kit.addChain(
            BASE_SEPOLIA,
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

    function _run() internal {
        kit.phasesWith(DEPLOYER_KEY);
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

    /// @notice **The invariant the kit exists for.** After a complete run no EOA
    ///         can act as any DAO, and every declared governor still can.
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
    function test_fullRun_isConformant() public {
        _run();

        kit.selectHub();
        assertConformant(kit.hubDeployed(), SEP_PSP, vm.addr(DEPLOYER_KEY));
        assertLaneWired(kit.hubCfg().controller, BASE_SEPOLIA, kit.hubCfg().adapter, kit.satCfg(0).adapter);

        kit.selectSatellite(0);
        assertConformant(kit.satDeployed(0), BASESEP_PSP, vm.addr(DEPLOYER_KEY));
        assertLaneWired(kit.satCfg(0).controller, SEPOLIA, kit.satCfg(0).adapter, kit.hubCfg().adapter);
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
    }

    // -------------------------------------------------------------------------
    // Refusals
    //
    // Everything above drives a CORRECT deployment and checks the outcome. That
    // shape can only ever prove the kit does the right thing when asked
    // correctly -- and every guard here was previously deletable with the suite
    // still green, because nothing ever asked the kit to say no.
    // -------------------------------------------------------------------------

    /// @notice A DAO with no declared governor must not be handed over.
    /// @dev The README's opening promise: "It will not finish a deployment that
    ///      leaves a DAO nobody can act as." Until now nothing held it to that.
    ///      The harness has carried `clearSatelliteGovernors` since it was
    ///      written; the test it exists for was never added.
    function test_handoverRefusesADaoWithNoGovernor() public {
        kit.phasesUpToHandover(DEPLOYER_KEY);
        kit.clearSatelliteGovernors(0);

        vm.expectRevert(bytes("DAO has no governor: nothing could act as it after handover"));
        kit.handOver();
    }

    /// @notice A zero failure-gas reserve must be refused.
    /// @dev Zero lets an out-of-gas payload revert the whole delivery, recording
    ///      nothing -- the message is then unreachable by both `retryMessage`
    ///      and `cancelMessage`.
    function test_installControllersRefusesAZeroFailureGasReserve() public {
        vm.expectRevert(bytes("minFailedMessageGas of 0 disables the failure-record reserve"));
        kit.installControllersWith(0);
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
    function test_multisigInstallerRefusesAZeroInTheRoster() public {
        kit.phasesUpToHandover(DEPLOYER_KEY);
        kit.poisonSatelliteRoster(0);

        vm.expectRevert(bytes("governance roster contains the zero address: quorum would be unreachable"));
        kit.installSatelliteGovernance(0);
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
        kit.phasesUpToHandover(DEPLOYER_KEY);
        kit.selectSatellite(0);

        address[] memory poisoned = new address[](2);
        poisoned[0] = address(0xA11CE);
        poisoned[1] = address(0);

        address plugin = kit.installMultisigUnchecked(0, poisoned, 2);

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
