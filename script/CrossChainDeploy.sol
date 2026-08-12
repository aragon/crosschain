// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Script, console } from "forge-std/Script.sol";

import { DAO } from "@aragon/osx/core/dao/DAO.sol";
import { DAOFactory } from "@aragon/osx/framework/dao/DAOFactory.sol";
import { PluginRepo } from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import { PluginRepoFactory } from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import { PluginSetupProcessor } from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {
    PluginSetupRef, hashHelpers
} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessorHelpers.sol";
import { PermissionManager } from "@aragon/osx/core/permission/PermissionManager.sol";
import { IPluginSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import { IExecutor, Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { CrossChainController } from "../src/CrossChainController.sol";
import { ICrossChainController } from "../src/ICrossChainController.sol";
import { CrossChainControllerSetup } from "../src/CrossChainControllerSetup.sol";
import { CCIPAdapter } from "../src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "../src/adapters/BaseAdapter.sol";

/// @title CrossChainDeploy
/// @notice Deploys a fresh DAO with the cross-chain controller on one hub chain
///         and N satellite chains, in a single run.
/// @dev **What a consumer supplies.** Two things: where the config comes from
///      (`_loadTopology`) and what governs each DAO (`_configureHub` /
///      `_configureSatellite`, added in a later task). Everything else — forks,
///      DAOs, controllers, adapters, routing, and the handover — is this
///      contract's, and is not overridable.
///
///      **The rule the seam is built on:** a hook may choose HOW something is
///      done; it may never choose WHETHER a safety property holds. Anything
///      that protects the deployment lives in non-virtual code here, so a
///      consumer cannot reach an unsafe state by overriding a default or by
///      forgetting to do something.
///
///      **Construction order matters and is easy to get wrong.** A contract
///      built *before any fork is selected* is reachable from every fork; one
///      built while a fork is selected belongs to that fork and is gone after
///      the next switch. `forge script` builds the script contract before
///      selecting anything, which is why this survives its own fork switches.
///      Test harnesses must construct in the same order. If you find yourself
///      reaching for `vm.makePersistent`, the order is wrong — fix that instead.
/// @custom:security-contact sirt@aragon.org
abstract contract CrossChainDeploy is Script {
    /// @notice One chain's inputs and everything the run produces for it.
    struct ChainCfg {
        // --- filled by `_loadTopology` ---
        uint256 chainId;
        /// @dev A `foundry.toml [rpc_endpoints]` alias or a URL; `vm.createFork`
        ///      accepts either.
        string rpc;
        address daoFactory;
        address psp;
        address pluginRepoFactory;
        address crossChainRepo;
        /// @dev Only needed by the default satellite installer; a consumer that
        ///      overrides `_configureSatellite` can leave it zero.
        address multisigRepo;
        address ccipRouter;
        /// @dev `address(0)` means CCIP fees are paid in the chain's native currency.
        address ccipFeeToken;
        string daoSubdomain;
        bytes daoMetadata;
        address[] members;
        uint16 minApprovals;
        // --- produced by the run ---
        uint256 forkId;
        address dao;
        address controller;
        address executor;
        address adapter;
        /// @dev Declared by a governance hook, verified before the handover.
        address[] governors;
    }

    ChainCfg internal hub;
    ChainCfg[] internal satellites;

    /// @notice Where the topology comes from.
    /// @dev The one hook with no safety dimension: it fills storage and nothing
    ///      else, so a consumer with its own config shape overrides it without
    ///      being able to weaken anything. Config never crosses the seam as
    ///      files — only as filled fields.
    function _loadTopology() internal virtual;

    /// @notice Fills the topology from a JSON file in the kit's own schema.
    /// @dev Offered, not imposed: a consumer whose config already exists in
    ///      another shape overrides `_loadTopology` and fills the same fields
    ///      itself.
    ///
    ///      Parsed as SCALARS, one path at a time. Array-valued JSON cheatcodes
    ///      generate ABI decoders heavy enough to overflow the stack in a
    ///      project that compiles without `via_ir` — and neither of the first
    ///      two consumers will enable it. `satelliteCount` exists so the
    ///      satellite list can be walked by index instead of decoded as an array
    ///      of structs, which is the worst case of all. The signer roster is the
    ///      one genuine array and is read in its own frame.
    function _loadTopologyFromJson(string memory _path) internal {
        require(vm.exists(_path), string.concat("topology not found: ", _path));
        string memory json = vm.readFile(_path);

        _readChain(json, ".hub", hub);
        minFailedMessageGas = vm.parseJsonUint(json, ".minFailedMessageGas");

        uint256 count = vm.parseJsonUint(json, ".satelliteCount");
        require(count > 0, "satelliteCount must be > 0");
        for (uint256 i = 0; i < count; i++) {
            satellites.push();
            _readChain(json, string.concat(".satellites[", vm.toString(i), "]"), satellites[i]);
            require(satellites[i].chainId != hub.chainId, "satellite chain id equals the hub");
        }
    }

    function _readChain(string memory _json, string memory _at, ChainCfg storage _chain) private {
        _chain.chainId = vm.parseJsonUint(_json, string.concat(_at, ".chainId"));
        _chain.rpc = vm.parseJsonString(_json, string.concat(_at, ".rpc"));
        _chain.daoFactory = vm.parseJsonAddress(_json, string.concat(_at, ".daoFactory"));
        _chain.psp = vm.parseJsonAddress(_json, string.concat(_at, ".psp"));
        _chain.pluginRepoFactory = vm.parseJsonAddress(_json, string.concat(_at, ".pluginRepoFactory"));
        _chain.crossChainRepo = vm.parseJsonAddress(_json, string.concat(_at, ".crossChainRepo"));
        _chain.multisigRepo = vm.parseJsonAddress(_json, string.concat(_at, ".multisigRepo"));
        _chain.ccipRouter = vm.parseJsonAddress(_json, string.concat(_at, ".ccipRouter"));
        _chain.ccipFeeToken = vm.parseJsonAddress(_json, string.concat(_at, ".ccipFeeToken"));
        _chain.daoSubdomain = vm.parseJsonString(_json, string.concat(_at, ".dao.subdomain"));
        _chain.daoMetadata = bytes(vm.parseJsonString(_json, string.concat(_at, ".dao.metadata")));

        _requireChain(_chain);
        _readRoster(_json, _at, _chain);
    }

    /// @dev Its own frame: the address-array decoder is the heaviest thing here.
    function _readRoster(string memory _json, string memory _at, ChainCfg storage _chain) private {
        _chain.minApprovals = uint16(vm.parseJsonUint(_json, string.concat(_at, ".governance.minApprovals")));
        address[] memory members = vm.parseJsonAddressArray(_json, string.concat(_at, ".governance.members"));
        for (uint256 i = 0; i < members.length; i++) {
            _chain.members.push(members[i]);
        }
    }

    /// @dev Placeholders are rejected before anything is broadcast. A zero here
    ///      is not a default, it is an unfinished config.
    function _requireChain(ChainCfg storage _chain) private view {
        require(_chain.chainId != 0, "chainId missing");
        require(bytes(_chain.rpc).length > 0, "rpc missing");
        require(_chain.daoFactory != address(0), "daoFactory missing");
        require(_chain.psp != address(0), "psp missing");
        require(_chain.crossChainRepo != address(0), "crossChainRepo missing");
        require(_chain.ccipRouter != address(0), "ccipRouter missing");
    }

    /// @notice One fork per chain.
    /// @dev `virtual` only so a test harness can supply forks it already made,
    ///      which is a mechanism concession rather than a policy one.
    function _createForks() internal virtual {
        hub.forkId = vm.createFork(hub.rpc);
        for (uint256 i = 0; i < satellites.length; i++) {
            satellites[i].forkId = vm.createFork(satellites[i].rpc);
        }
    }

    /// @notice Selects a chain's fork and asserts it really is that chain.
    /// @dev Not overridable, and checked after *every* switch rather than once
    ///      at the start. A wrong RPC is not a recoverable mistake: an adapter
    ///      takes its trusted remote in the constructor and has no setter, so a
    ///      lane keyed to the wrong chain is permanent.
    function _select(ChainCfg storage _chain) internal {
        vm.selectFork(_chain.forkId);
        if (block.chainid != _chain.chainId) {
            console.log("RPC/chain id mismatch - config says:", _chain.chainId);
            console.log("                        fork says:  ", block.chainid);
            revert("RPC does not match the configured chain id");
        }
    }

    /// @notice How many chains this deployment spans, hub included.
    function chainCount() public view returns (uint256) {
        return satellites.length + 1;
    }

    // -------------------------------------------------------------------------
    // Signing
    // -------------------------------------------------------------------------

    /// @notice The account every phase broadcasts from.
    address internal deployer;

    /// @dev Zero means "whatever forge's own `--account` / `--ledger` /
    ///      `--private-key` resolved", which is what production uses. A non-zero
    ///      key is the test path: fork suites need a specific funded address,
    ///      and passing it as an argument keeps them off `vm.setEnv`, which is
    ///      process-global and races concurrent tests.
    ///
    ///      Deliberately not read from the environment. A plaintext key in a
    ///      shell is visible to every process, lands in history, and leaves no
    ///      record of which key signed a deployment.
    uint256 internal deployerKey;

    function _broadcast() internal {
        if (deployerKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerKey);
        }
    }

    /// @dev `msg.sender` inside the script's own frame is whoever called the
    ///      entry point, NOT the broadcaster — `startBroadcast` changes the
    ///      sender of the calls the script MAKES, not the frame evaluating the
    ///      arguments. Reading `msg.sender` to mean "the deployer" silently
    ///      addresses the wrong account.
    function _resolveDeployer() internal view returns (address) {
        return deployerKey == 0 ? msg.sender : vm.addr(deployerKey);
    }

    // -------------------------------------------------------------------------
    // Phase 2 — the DAOs
    // -------------------------------------------------------------------------

    /// @notice A DAO on every chain, created with NO plugins.
    /// @dev `DAOFactory` still registers it — so the Aragon App indexes it — and,
    ///      seeing an empty plugin array, grants `EXECUTE_PERMISSION` to the
    ///      caller. That grant is what lets every later phase run unattended,
    ///      and the final phase is what takes it back.
    ///
    ///      The kit creates every DAO, without exception. That is what makes
    ///      "the deployer can act as this DAO" structural rather than something
    ///      a consumer has to remember to arrange.
    function _createDaos() internal {
        _select(hub);
        _broadcast();
        hub.dao = _createBareDao(hub);
        vm.stopBroadcast();
        console.log("[2] hub DAO", hub.dao);

        for (uint256 i = 0; i < satellites.length; i++) {
            _select(satellites[i]);
            _broadcast();
            satellites[i].dao = _createBareDao(satellites[i]);
            vm.stopBroadcast();
            console.log("[2] satellite DAO", satellites[i].dao);
        }
    }

    function _createBareDao(ChainCfg storage _chain) private returns (address) {
        (DAO created,) = DAOFactory(_chain.daoFactory).createDao(
            DAOFactory.DAOSettings({
                trustedForwarder: address(0),
                daoURI: "",
                subdomain: _chain.daoSubdomain,
                metadata: _chain.daoMetadata
            }),
            new DAOFactory.PluginSettings[](0)
        );
        return address(created);
    }

    // -------------------------------------------------------------------------
    // Available to governance hooks
    // -------------------------------------------------------------------------

    bytes32 internal constant ROOT_PERMISSION_ID = keccak256("ROOT_PERMISSION");
    bytes32 internal constant EXECUTE_PERMISSION_ID = keccak256("EXECUTE_PERMISSION");

    /// @notice Prepares an installation and applies it in the same transaction.
    /// @dev This is what makes an action-bundle file unnecessary.
    ///      `prepareInstallation` returns the permission set and helpers ONCE —
    ///      the PSP stores only a hash of them, and `applyInstallation` rejects
    ///      any mismatch — so a step-by-step flow has to carry them between
    ///      processes somehow. Applying inline removes the requirement instead
    ///      of working around it.
    ///
    ///      Three actions, not five: they execute AS the DAO, and
    ///      `PluginSetupProcessor._canApply` short-circuits on
    ///      `msg.sender == _dao`, so no `APPLY_INSTALLATION_PERMISSION` grant is
    ///      needed. The PSP holds `ROOT` for one transaction and not a block
    ///      longer.
    ///
    ///      Must be called inside an active broadcast.
    function _installPlugin(ChainCfg storage _chain, PluginRepo _repo, PluginRepo.Tag memory _tag, bytes memory _data)
        internal
        returns (address plugin, address[] memory helpers)
    {
        PluginSetupRef memory ref = PluginSetupRef({ versionTag: _tag, pluginSetupRepo: _repo });

        IPluginSetup.PreparedSetupData memory prepared;
        (plugin, prepared) = PluginSetupProcessor(_chain.psp).prepareInstallation(
            _chain.dao, PluginSetupProcessor.PrepareInstallationParams({ pluginSetupRef: ref, data: _data })
        );
        helpers = prepared.helpers;

        Action[] memory actions = new Action[](3);
        actions[0].to = _chain.dao;
        actions[0].data =
            abi.encodeCall(PermissionManager.grant, (_chain.dao, _chain.psp, ROOT_PERMISSION_ID));
        actions[1].to = _chain.psp;
        actions[1].data = abi.encodeCall(
            PluginSetupProcessor.applyInstallation,
            (
                _chain.dao,
                PluginSetupProcessor.ApplyInstallationParams({
                    pluginSetupRef: ref,
                    plugin: plugin,
                    permissions: prepared.permissions,
                    helpersHash: hashHelpers(prepared.helpers)
                })
            )
        );
        actions[2].to = _chain.dao;
        actions[2].data =
            abi.encodeCall(PermissionManager.revoke, (_chain.dao, _chain.psp, ROOT_PERMISSION_ID));

        IExecutor(_chain.dao).execute(bytes32(0), actions, 0);
    }

    /// @notice Publishes a plugin repo on the chain in scope.
    /// @dev For consumers self-publishing rather than installing from a repo
    ///      someone else deployed. Satellite chains rarely have one published.
    ///      Empty subdomain: the repo is addressed directly, so no ENS
    ///      registration is needed. Must be called inside an active broadcast.
    function _publishRepo(ChainCfg storage _chain, address _setup) internal returns (PluginRepo) {
        return PluginRepoFactory(_chain.pluginRepoFactory).createPluginRepoWithFirstVersion(
            "", _setup, _resolveDeployer(), bytes("kit"), bytes("kit")
        );
    }

    /// @notice Grants `EXECUTE` on this chain's DAO, executed AS the DAO.
    /// @dev Only works while the deployer still holds `EXECUTE` itself, i.e.
    ///      before the handover. Must be called inside an active broadcast.
    function _grantExecute(ChainCfg storage _chain, address _who) internal {
        _daoAction(_chain, abi.encodeCall(PermissionManager.grant, (_chain.dao, _who, EXECUTE_PERMISSION_ID)));
    }

    /// @notice Takes `EXECUTE` back from an address a hook granted it to.
    /// @dev The pairing matters. A helper contract that configures a DAO during
    ///      the run — a governance factory, say — needs `EXECUTE` to act as it,
    ///      and needs to lose it again before the handover, or the deployment
    ///      ends with a second unconditional authority nobody accounted for.
    ///      `_assertGovernable` would not catch that: it checks the declared
    ///      governors CAN execute, not that nothing else can.
    function _revokeExecute(ChainCfg storage _chain, address _who) internal {
        _daoAction(_chain, abi.encodeCall(PermissionManager.revoke, (_chain.dao, _who, EXECUTE_PERMISSION_ID)));
    }

    function _grantRoot(ChainCfg storage _chain, address _who) internal {
        _daoAction(_chain, abi.encodeCall(PermissionManager.grant, (_chain.dao, _who, ROOT_PERMISSION_ID)));
    }

    function _revokeRoot(ChainCfg storage _chain, address _who) internal {
        _daoAction(_chain, abi.encodeCall(PermissionManager.revoke, (_chain.dao, _who, ROOT_PERMISSION_ID)));
    }

    /// @dev Executes one call AS the DAO, against the DAO itself. For permission
    ///      changes, where the DAO is both the caller and the target.
    function _daoAction(ChainCfg storage _chain, bytes memory _data) private {
        _daoActionTo(_chain, _chain.dao, _data);
    }

    /// @dev Executes one call AS the DAO, against `_target`. Needed wherever the
    ///      DAO acts on something else — `updateConfig` on the controller, say —
    ///      which is not the same thing as acting on itself.
    function _daoActionTo(ChainCfg storage _chain, address _target, bytes memory _data) private {
        Action[] memory actions = new Action[](1);
        actions[0].to = _target;
        actions[0].data = _data;
        IExecutor(_chain.dao).execute(bytes32(0), actions, 0);
    }

    // -------------------------------------------------------------------------
    // Phase 3 — the controllers
    // -------------------------------------------------------------------------

    /// @notice The release this kit installs.
    /// @dev Pinned rather than read as "latest": in OSx a new RELEASE is an
    ///      incompatible plugin, not a patch.
    uint8 internal constant CROSS_CHAIN_RELEASE = 1;

    /// @notice Install parameter: let the setup mint a dedicated `Executor` and
    ///         transfer its ownership to the controller.
    /// @dev Not a parameter a consumer can change, and that is the point. Naming
    ///      the DAO instead sets `_executorIsDao` in `CrossChainControllerSetup`,
    ///      which grants the controller `EXECUTE_PERMISSION` **on the DAO** — so
    ///      any inbound message clearing the adapter would execute with full DAO
    ///      authority. Inbound payloads run as the `Executor` instead, and that
    ///      is the address remote roles must be granted to.
    address internal constant DEDICATED_EXECUTOR = address(0);

    /// @notice The build resolved on the hub, then required on every satellite.
    uint16 internal pinnedBuild;

    /// @notice Installs the controller on every chain.
    /// @dev One sweep, and it must finish everywhere before phase 4 starts on
    ///      any chain: an adapter takes its trusted remote — the controller on
    ///      the OTHER side — in the constructor and has no setter.
    function _installControllers(uint256 _minFailedMessageGas) internal {
        require(_minFailedMessageGas > 0, "minFailedMessageGas of 0 disables the failure-record reserve");

        _installController(hub, _minFailedMessageGas);
        for (uint256 i = 0; i < satellites.length; i++) {
            _installController(satellites[i], _minFailedMessageGas);
        }
    }

    function _installController(ChainCfg storage _chain, uint256 _minFailedMessageGas) private {
        _select(_chain);

        PluginRepo repo = PluginRepo(_chain.crossChainRepo);
        _requireInstallableRepo(repo);

        // Resolved as "latest" on the HUB only, then that exact build is demanded
        // everywhere else. Each chain has its own repo with its own publishing
        // history, so asking each for "latest" independently puts different
        // builds on the two ends of a lane whenever one chain is ahead — or
        // whenever a build lands mid-run, which is a slow sweep across several
        // chains. A satellite whose repo lacks the build reverts here.
        PluginRepo.Version memory version;
        if (pinnedBuild == 0) {
            version = repo.getLatestVersion(CROSS_CHAIN_RELEASE);
            pinnedBuild = version.tag.build;
        } else {
            version = repo.getVersion(PluginRepo.Tag({ release: CROSS_CHAIN_RELEASE, build: pinnedBuild }));
        }

        // The pause guardian is always this chain's own DAO, and not
        // configurable. The setup grants the DAO `PAUSE_PERMISSION`
        // unconditionally, so any OTHER guardian would be an ADDITIONAL one that
        // can freeze every message on the chain, never receives `UNPAUSE`, and
        // is not revoked by an uninstall.
        bytes memory data = CrossChainControllerSetup(version.pluginSetup).encodeInstallationParameters(
            DEDICATED_EXECUTOR, _chain.dao, _minFailedMessageGas
        );

        _broadcast();
        (address plugin, address[] memory helpers) = _installPlugin(_chain, repo, version.tag, data);
        vm.stopBroadcast();

        require(helpers.length == 1, "unexpected helper count from CrossChainControllerSetup");
        _chain.controller = plugin;
        _chain.executor = helpers[0];

        console.log("[3] controller", plugin);
        console.log("    executor (owner = controller)", helpers[0]);
    }

    /// @dev The repo address is an input, so a wrong one is a config error worth
    ///      catching loudly: a non-repo reverts uninformatively deep inside the
    ///      PSP, and a wrong-but-real repo would install some other project's
    ///      plugin as this DAO's controller. This cannot tell you it is the
    ///      RIGHT repo — only that it is a repo with a published build.
    function _requireInstallableRepo(PluginRepo _repo) private view {
        require(address(_repo).code.length > 0, "crossChainRepo has no code");
        require(_repo.latestRelease() >= CROSS_CHAIN_RELEASE, "crossChainRepo has no published release");
        require(_repo.buildCount(CROSS_CHAIN_RELEASE) > 0, "crossChainRepo has no build for the release");
    }

    // -------------------------------------------------------------------------
    // Phase 4 — adapters and routing
    // -------------------------------------------------------------------------

    /// @notice Deploys every adapter, then wires every lane.
    /// @dev Hub-and-spoke: the hub adapter trusts every satellite controller,
    ///      and each satellite adapter trusts only the hub. Satellites never
    ///      talk to each other.
    function _deployAdaptersAndRoute() internal {
        _deployHubAdapter();
        for (uint256 i = 0; i < satellites.length; i++) {
            _deploySatelliteAdapter(i);
        }

        _routeHub();
        for (uint256 i = 0; i < satellites.length; i++) {
            _routeSatellite(i);
        }
    }

    function _deployHubAdapter() private {
        _select(hub);

        BaseAdapter.TrustedRemoteConfig[] memory trusted =
            new BaseAdapter.TrustedRemoteConfig[](satellites.length);
        for (uint256 i = 0; i < satellites.length; i++) {
            require(satellites[i].controller != address(0), "satellite controller missing: install controllers first");
            trusted[i] = BaseAdapter.TrustedRemoteConfig({
                standardChainId: satellites[i].chainId,
                trustedRemote: satellites[i].controller
            });
        }

        _broadcast();
        hub.adapter = address(new CCIPAdapter(hub.controller, hub.ccipRouter, hub.ccipFeeToken, trusted));
        vm.stopBroadcast();
        console.log("[4] hub adapter", hub.adapter);
    }

    function _deploySatelliteAdapter(uint256 _i) private {
        _select(satellites[_i]);
        require(hub.controller != address(0), "hub controller missing: install controllers first");

        BaseAdapter.TrustedRemoteConfig[] memory trusted = new BaseAdapter.TrustedRemoteConfig[](1);
        trusted[0] =
            BaseAdapter.TrustedRemoteConfig({ standardChainId: hub.chainId, trustedRemote: hub.controller });

        _broadcast();
        satellites[_i].adapter = address(
            new CCIPAdapter(
                satellites[_i].controller, satellites[_i].ccipRouter, satellites[_i].ccipFeeToken, trusted
            )
        );
        vm.stopBroadcast();
        console.log("[4] satellite adapter", satellites[_i].adapter);
    }

    function _routeHub() private {
        uint256[] memory chainIds = new uint256[](satellites.length);
        ICrossChainController.ChainConfig[] memory configs =
            new ICrossChainController.ChainConfig[](satellites.length);

        for (uint256 i = 0; i < satellites.length; i++) {
            chainIds[i] = satellites[i].chainId;
            configs[i] = ICrossChainController.ChainConfig({
                localAdapter: hub.adapter,
                remoteAdapter: satellites[i].adapter
            });
        }

        _updateConfig(hub, chainIds, configs);
    }

    function _routeSatellite(uint256 _i) private {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = hub.chainId;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] = ICrossChainController.ChainConfig({
            localAdapter: satellites[_i].adapter,
            remoteAdapter: hub.adapter
        });

        _updateConfig(satellites[_i], chainIds, configs);
    }

    /// @dev `updateConfig` is gated by `MANAGE_CONTROLLER_CONFIG_PERMISSION`,
    ///      which the installation granted to the DAO, so it runs through the DAO.
    function _updateConfig(
        ChainCfg storage _chain,
        uint256[] memory _chainIds,
        ICrossChainController.ChainConfig[] memory _configs
    )
        private
    {
        _select(_chain);
        _broadcast();
        // Targets the CONTROLLER, not the DAO: `updateConfig` is gated by
        // `MANAGE_CONTROLLER_CONFIG_PERMISSION`, which the installation granted
        // to the DAO, so the DAO is the caller and the controller is the callee.
        _daoActionTo(
            _chain, _chain.controller, abi.encodeCall(CrossChainController.updateConfig, (_chainIds, _configs))
        );
        vm.stopBroadcast();
        console.log("[4] routed lanes", _chainIds.length);
    }

    // -------------------------------------------------------------------------
    // Phase 5 — governance
    // -------------------------------------------------------------------------

    /// @notice Install whatever governs the hub DAO.
    /// @dev Runs LAST, after the cross-chain stack is complete, with the
    ///      deployer still holding `EXECUTE` on every DAO. So it can install
    ///      plugins, grant permissions, seed a treasury — anything — and it sees
    ///      final controller, executor and adapter addresses.
    ///
    ///      MUST declare at least one governor via {_addGovernor}. The kit
    ///      verifies them and refuses to hand over otherwise; that check is not
    ///      overridable.
    function _configureHub() internal virtual;

    /// @notice Install whatever governs satellite `_i`.
    /// @dev Defaults to a Multisig from `multisigRepo`. Overridable — the
    ///      postcondition is what protects the deployment, so a project with its
    ///      own L2 governance is not forced to carry a multisig it will not use.
    function _configureSatellite(uint256 _i) internal virtual {
        _installMultisigGovernance(satellites[_i]);
    }

    /// @notice Declares an address that must be able to execute as this DAO.
    /// @dev Plural on purpose. Real governance is often several contracts — two
    ///      staged processors plus an emergency Safe, say — and a single-address
    ///      check pointed at the Safe would pass while a processor's grant had
    ///      silently failed, leaving a DAO that looks governed and cannot pass a
    ///      proposal.
    function _addGovernor(ChainCfg storage _chain, address _governor) internal {
        _chain.governors.push(_governor);
    }

    /// @notice The kit's satellite governance: a Multisig that can act as the DAO.
    /// @dev The `_grantExecute` at the end is belt-and-braces, not the load-
    ///      bearing step — and the distinction is worth stating because it is
    ///      easy to get backwards. Aragon's published `MultisigSetup` DOES grant
    ///      the plugin `EXECUTE` on the DAO as part of its permission set, so
    ///      against that repo this call is a no-op (OSx treats a repeat grant as
    ///      one). But `multisigRepo` is an input, and not every setup does:
    ///      alchemix ships a custom `MultisigSetup` that grants the DAO rights
    ///      over the plugin and makes proposal execution permissionless while
    ///      granting NO `EXECUTE` on the DAO. Installed from that repo without
    ///      this line, the DAO would be exactly as frozen as with no governance
    ///      at all.
    ///
    ///      So the grant makes this installer correct for whatever repo it is
    ///      pointed at, rather than only for the one the tests happen to use.
    ///      `_assertGovernable` is the real backstop either way.
    function _installMultisigGovernance(ChainCfg storage _chain) internal {
        require(_chain.multisigRepo != address(0), "multisigRepo missing: needed by the default governance");
        require(_chain.members.length > 0, "governance roster is empty");
        require(_chain.minApprovals > 0, "minApprovals must be at least 1");
        require(_chain.minApprovals <= _chain.members.length, "minApprovals exceeds the roster size");

        PluginRepo repo = PluginRepo(_chain.multisigRepo);
        PluginRepo.Version memory version = repo.getLatestVersion(repo.latestRelease());

        bytes memory data = abi.encode(
            _chain.members,
            MultisigSettings({ onlyListed: true, minApprovals: _chain.minApprovals }),
            TargetConfig({ target: address(0), operation: 0 }),
            bytes("")
        );

        _broadcast();
        (address plugin,) = _installPlugin(_chain, repo, version.tag, data);
        _grantExecute(_chain, plugin);
        vm.stopBroadcast();

        _addGovernor(_chain, plugin);
        console.log("[5] multisig governance", plugin);
    }

    /// @dev Declared locally: the Multisig plugin is not a dependency of this
    ///      package, and the encoding was verified against the live setup rather
    ///      than assumed. `target: address(0)` resolves to the DAO, so the
    ///      multisig acts THROUGH it; `operation: 0` is `Call`.
    struct MultisigSettings {
        bool onlyListed;
        uint16 minApprovals;
    }

    struct TargetConfig {
        address target;
        uint8 operation;
    }

    function _configureGovernance() internal {
        _select(hub);
        _configureHub();
        _assertGovernable(hub);

        for (uint256 i = 0; i < satellites.length; i++) {
            _select(satellites[i]);
            _configureSatellite(i);
            _assertGovernable(satellites[i]);
        }
    }

    /// @notice Every DAO must end able to act. Not overridable, checked twice.
    /// @dev The failure this prevents: a DAO with no `EXECUTE` holder is inert
    ///      forever, and the cross-chain controller grants
    ///      `MANAGE_CONTROLLER_CONFIG`, `CANCEL_MESSAGE`, `SWEEP`, `PAUSE`,
    ///      `UNPAUSE` and `UPGRADE_PLUGIN` to the DAO and to nobody else. So a
    ///      frozen DAO means a wrong lane cannot be repaired, a stranded message
    ///      cannot be cancelled, a paused controller cannot be unpaused, and an
    ///      upstream security fix cannot be applied. Permanently.
    function _assertGovernable(ChainCfg storage _chain) internal view {
        require(_chain.governors.length > 0, "DAO has no governor: nothing could act as it after handover");
        for (uint256 i = 0; i < _chain.governors.length; i++) {
            require(
                DAO(payable(_chain.dao)).hasPermission(
                    _chain.dao, _chain.governors[i], EXECUTE_PERMISSION_ID, ""
                ),
                "declared governor cannot execute as the DAO"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Phase 6 — handover
    // -------------------------------------------------------------------------

    /// @notice Takes `EXECUTE` away from the deployer on every chain.
    /// @dev MUST be last: every phase above is authorised by this permission.
    ///      Irreversible, so the governability check runs once more immediately
    ///      before it rather than being trusted from phase 5.
    ///
    ///      Self-revoking, and safe: the deployer executes it AS the DAO, and the
    ///      DAO holds `ROOT` on itself, so this is the deployer's last act with
    ///      the authority it is giving up. A failed transaction leaves the
    ///      permission in place and can be retried.
    function _handOver() internal {
        _revokeDeployer(hub);
        for (uint256 i = 0; i < satellites.length; i++) {
            _revokeDeployer(satellites[i]);
        }
    }

    function _revokeDeployer(ChainCfg storage _chain) private {
        _select(_chain);
        _assertGovernable(_chain);

        _broadcast();
        _daoAction(
            _chain, abi.encodeCall(PermissionManager.revoke, (_chain.dao, deployer, EXECUTE_PERMISSION_ID))
        );
        vm.stopBroadcast();
        console.log("[6] deployer EXECUTE revoked on", _chain.chainId);
    }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() public {
        runWith(0);
    }

    /// @notice The whole deployment, in order.
    /// @dev The order is the specification. Controllers are one sweep because an
    ///      adapter needs the controller on the other side; adapters precede
    ///      routing for the same reason one step further out; governance is last
    ///      but one because nothing earlier needs it; the handover is last
    ///      because it removes the authority every phase above used.
    function runWith(uint256 _deployerKey) public {
        deployerKey = _deployerKey;
        deployer = _resolveDeployer();

        _loadTopology();
        _createForks();
        phases();
    }

    /// @notice Every phase against forks that already exist.
    /// @dev Split from {runWith} so a caller that must touch the forks first can
    ///      still drive the real sequence — a fork suite funds the deployer on
    ///      each chain, which has to happen on the same forks the phases use.
    function phases() public {
        _createDaos();
        _installControllers(minFailedMessageGas);
        _deployAdaptersAndRoute();
        _configureGovernance();
        _handOver();
        _report();
    }

    /// @notice Gas the controller withholds so a failed inbound message is
    ///         recorded as `Delivered` rather than reverting the whole delivery.
    /// @dev Never zero: a zero reserve lets an out-of-gas payload revert the
    ///      delivery, recording nothing, and the message is then unreachable by
    ///      both `retryMessage` and `cancelMessage`.
    uint256 internal minFailedMessageGas = 45_000;

    /// @dev The run's only output. Capture it — the kit writes no files.
    function _report() internal {
        console.log("================ DEPLOYMENT COMPLETE ================");
        _reportChain("hub", hub);
        for (uint256 i = 0; i < satellites.length; i++) {
            _reportChain("satellite", satellites[i]);
        }
        console.log("Fund the HUB controller with native currency for CCIP fees:", hub.controller);
        console.log("Never the adapter: assets sent there are stranded, it has no rescue path.");
    }

    function _reportChain(string memory _label, ChainCfg storage _chain) private view {
        console.log("---", _label, _chain.chainId);
        console.log("  dao       ", _chain.dao);
        console.log("  controller", _chain.controller);
        console.log("  executor  ", _chain.executor);
        console.log("  adapter   ", _chain.adapter);
        for (uint256 i = 0; i < _chain.governors.length; i++) {
            console.log("  governor  ", _chain.governors[i]);
        }
    }
}
