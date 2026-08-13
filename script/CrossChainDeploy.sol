// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Script, console } from "forge-std/Script.sol";

import { DAO } from "@aragon/osx/core/dao/DAO.sol";
import { DAOFactory } from "@aragon/osx/framework/dao/DAOFactory.sol";
import { PluginRepo } from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import { PluginRepoFactory } from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import { PluginSetupProcessor } from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import { PluginSetupRef, hashHelpers } from "@aragon/osx/framework/plugin/setup/PluginSetupProcessorHelpers.sol";
import { PermissionManager } from "@aragon/osx/core/permission/PermissionManager.sol";
import { PermissionLib } from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import { IPluginSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import { IExecutor, Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";

import { CrossChainController } from "../src/CrossChainController.sol";
import { ICrossChainController } from "../src/ICrossChainController.sol";
import { CrossChainControllerSetup } from "../src/CrossChainControllerSetup.sol";
import { CCIPAdapter } from "../src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "../src/adapters/BaseAdapter.sol";
import { IBaseAdapter } from "../src/adapters/IBaseAdapter.sol";
import { TestnetCCIPAdapter } from "./testnet/TestnetCCIPAdapter.sol";

/// @title CrossChainDeploy
/// @notice Gives a consumer-owned hub DAO the whole cross-chain stack — the
///         controller on the hub and on N satellite chains, satellite DAOs, the
///         adapters and the routing — in two calls.
/// @dev **The consumer sequence.** `initCrosschain()` resolves the signer,
///      loads the topology and creates the forks, leaving the HUB fork
///      selected; the consumer then creates its own DAO there and, still
///      holding `EXECUTE` on it, calls `setUpCrosschain()` followed by
///      `installCrosschain()`. The split exists because satellite adapters
///      bake the hub controller in at construction: the first call prepares
///      the hub controller (permissionless, so the address is known) and
///      builds every satellite end to end; the second applies that prepared
///      install onto the hub DAO and wires the hub's lanes.
///
///      **What a consumer supplies.** Where the config comes from
///      (`_loadTopology`), the hub DAO itself, and what governs it. Satellite
///      governance defaults to a Multisig (`_configureSatellite`). Everything
///      else — forks, satellite DAOs, controllers, adapters, routing, and the
///      satellite handover — is this contract's, and is not overridable.
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

    /// @dev Foundry's own default script sender, used whenever nothing else set
    ///      one: `address(uint160(uint256(keccak256("foundry default caller"))))`.
    address internal constant FOUNDRY_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    /// @dev `msg.sender` inside the script's own frame is whoever called the
    ///      entry point, NOT the broadcaster — `startBroadcast` changes the
    ///      sender of the calls the script MAKES, not the frame evaluating the
    ///      arguments. Reading `msg.sender` to mean "the deployer" silently
    ///      addresses the wrong account.
    ///
    ///      Worse, forge only populates the script sender from `--private-key`.
    ///      Under `--account` or `--ledger` it stays at {FOUNDRY_DEFAULT_SENDER}
    ///      while an entirely different wallet signs — measured against forge
    ///      1.3.5 and 1.6.0. That is the dangerous combination, and it is the one
    ///      every README here recommends: `DAOFactory` grants `EXECUTE` to the
    ///      real signer, phase 6 revokes it from the constant, OSx's `_revoke`
    ///      no-ops on a permission that was never set, and the run prints success
    ///      while the signing EOA keeps unconditional `EXECUTE` on every DAO for
    ///      good.
    ///
    ///      So refuse to guess rather than guess wrong. Checked again from the
    ///      other side once the DAOs exist — see {_assertDeployerBootstrapped}.
    function _resolveDeployer() internal view returns (address) {
        if (deployerKey != 0) return vm.addr(deployerKey);

        require(
            msg.sender != FOUNDRY_DEFAULT_SENDER,
            "cannot resolve the signing address: under --account/--ledger forge leaves the script sender at its default, so the handover would revoke EXECUTE from the wrong account and the real signer would keep it. Pass --sender <the signing address> too, or set PRIVATE_KEY."
        );
        return msg.sender;
    }

    // -------------------------------------------------------------------------
    // Phase 2 — the DAOs
    // -------------------------------------------------------------------------

    /// @notice A DAO on every satellite chain, created with NO plugins.
    /// @dev `DAOFactory` still registers it — so the Aragon App indexes it — and,
    ///      seeing an empty plugin array, grants `EXECUTE_PERMISSION` to the
    ///      caller. That grant is what lets every later phase run unattended,
    ///      and the final phase is what takes it back.
    ///
    ///      Satellites only. The hub DAO is the consumer's — created by it,
    ///      between `initCrosschain()` and `setUpCrosschain()`, on the kit's hub
    ///      fork — so "the deployer can act as it" is checked as a precondition
    ///      rather than guaranteed by construction.
    function _createSatelliteDaos() internal {
        for (uint256 i = 0; i < satellites.length; i++) {
            _select(satellites[i]);
            _broadcast();
            satellites[i].dao = _createBareDao(satellites[i]);
            vm.stopBroadcast();
            _assertDeployerBootstrapped(satellites[i]);
            console.log("[2] satellite DAO", satellites[i].dao);
        }
    }

    /// @dev The whole deployment rests on one assumption: that `deployer` names
    ///      the account `DAOFactory` just granted `EXECUTE` to. Everything after
    ///      this point acts as the DAO through that grant, and phase 6 revokes
    ///      exactly that address.
    ///
    ///      Nothing before now can prove it. {_resolveDeployer} rejects the one
    ///      case it can recognise, but an operator who passes a `--sender` that
    ///      is merely WRONG — a second account in the same keystore, a typo, the
    ///      Safe rather than its signer — produces the identical silent failure:
    ///      a revoke against an address that holds nothing, and a real signer
    ///      left with permanent authority over every DAO in the topology.
    ///
    ///      Reading the grant back settles it against on-chain state instead of
    ///      against a guess about how forge resolved a flag. Two views cost
    ///      nothing and this aborts before any authority has been handed out.
    function _assertDeployerBootstrapped(ChainCfg storage _chain) private view {
        require(
            DAO(payable(_chain.dao)).hasPermission(_chain.dao, deployer, EXECUTE_PERMISSION_ID, ""),
            "the resolved deployer does not hold EXECUTE on the DAO it just created: the signing account differs from the resolved one, so the handover would revoke nothing. Pass --sender <the signing address>, or set PRIVATE_KEY."
        );
    }

    function _createBareDao(ChainCfg storage _chain) private returns (address) {
        (DAO created,) = DAOFactory(_chain.daoFactory)
            .createDao(
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
        (plugin, prepared) = PluginSetupProcessor(_chain.psp)
            .prepareInstallation(
                _chain.dao, PluginSetupProcessor.PrepareInstallationParams({ pluginSetupRef: ref, data: _data })
            );
        helpers = prepared.helpers;

        Action[] memory actions = new Action[](3);
        actions[0].to = _chain.dao;
        actions[0].data = abi.encodeCall(PermissionManager.grant, (_chain.dao, _chain.psp, ROOT_PERMISSION_ID));
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
        actions[2].data = abi.encodeCall(PermissionManager.revoke, (_chain.dao, _chain.psp, ROOT_PERMISSION_ID));

        IExecutor(_chain.dao).execute(bytes32(0), actions, 0);
    }

    /// @notice Publishes a plugin repo on the chain in scope.
    /// @dev For consumers self-publishing rather than installing from a repo
    ///      someone else deployed. Satellite chains rarely have one published.
    ///      Empty subdomain: the repo is addressed directly, so no ENS
    ///      registration is needed. Must be called inside an active broadcast.
    function _publishRepo(ChainCfg storage _chain, address _setup) internal returns (PluginRepo) {
        return _publishRepo(_chain, _setup, bytes("kit"), bytes("kit"));
    }

    /// @notice As above, with real metadata URIs.
    /// @dev Build metadata is write-once — `PluginRepo` offers
    ///      `updateReleaseMetadata` and no build equivalent — so a placeholder
    ///      here is permanent for release 1 build 1, and the Aragon App and
    ///      subgraph cannot render a plugin whose build URI does not resolve.
    ///      Recoverable only by publishing a second build.
    ///
    ///      The maintainer is the DAO, not the deploying account, and that is the
    ///      part worth reading twice. `PluginRepoFactory` grants the maintainer
    ///      `ROOT`, `MAINTAINER` and `UPGRADE_REPO` on the new repo and revokes
    ///      only its own — none of which the handover touches, because the
    ///      handover is about `EXECUTE` on the DAO. An EOA maintainer therefore
    ///      keeps permanent authority over a repo the DAO will later install
    ///      from: it can publish a malicious build, or replace the repo
    ///      implementation outright via `UPGRADE_REPO`, and `applyInstallation`
    ///      would apply whatever permission set that build returns while the PSP
    ///      holds `ROOT`. Pinning a tag does not help. Nothing in the run needs
    ///      the EOA to hold it — `createPluginRepoWithFirstVersion` publishes
    ///      build 1 itself — so the DAO takes it from the start.
    function _publishRepo(
        ChainCfg storage _chain,
        address _setup,
        bytes memory _releaseMetadata,
        bytes memory _buildMetadata
    )
        internal
        returns (PluginRepo)
    {
        require(_chain.dao != address(0), "publish a repo after the DAOs exist: the DAO is the maintainer");
        return PluginRepoFactory(_chain.pluginRepoFactory)
            .createPluginRepoWithFirstVersion("", _setup, _chain.dao, _releaseMetadata, _buildMetadata);
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

    /// @notice What must survive between a controller's prepare and its apply.
    /// @dev `applyInstallation` recomputes the setup id from the caller-supplied
    ///      permissions, helpers hash and version tag, so those are stored here
    ///      verbatim; the plugin itself is in `ChainCfg.controller`. Keyed by
    ///      chain id because the hub's entry has to survive every satellite's
    ///      prepare/apply in between.
    ///
    ///      The permissions land element-wise, never by whole-array assignment:
    ///      copying a `MultiTargetPermission[] memory` into storage is solc
    ///      error 1834 in the legacy pipeline, and this project does not compile
    ///      with `via_ir`. The struct is static, so `push` works.
    struct PendingController {
        PluginRepo repo;
        PluginRepo.Tag tag;
        bytes32 helpersHash;
        PermissionLib.MultiTargetPermission[] permissions;
    }

    mapping(uint256 => PendingController) private pendingControllers;

    /// @notice Installs the controller on every satellite.
    /// @dev One sweep, and it must finish everywhere before the adapters exist
    ///      on any chain: an adapter takes its trusted remote — the controller
    ///      on the OTHER side — in the constructor and has no setter. The hub is
    ///      absent: its controller was prepared by `setUpCrosschain()` before
    ///      this ran, and is applied by `installCrosschain()`.
    function _installControllers() internal {
        for (uint256 i = 0; i < satellites.length; i++) {
            _prepareController(satellites[i]);
            _applyController(satellites[i]);
        }
    }

    /// @notice Deploys a chain's controller proxy and dedicated `Executor`, and
    ///         stores everything its `applyInstallation` will need.
    /// @dev `PSP.prepareInstallation` has no auth modifier, which is what makes
    ///      the two-call model possible at all: the hub controller's address is
    ///      known — and bakeable into satellite adapters — before anything has
    ///      acted as the hub DAO.
    function _prepareController(ChainCfg storage _chain) internal returns (address plugin) {
        // Checked at prepare, not at apply: the value is baked into the proxy's
        // `initialize` here, so a later check would be reading a decision
        // already taken. Zero lets an out-of-gas payload revert the whole
        // delivery, recording nothing — the message is then unreachable by both
        // `retryMessage` and `cancelMessage`.
        require(minFailedMessageGas > 0, "minFailedMessageGas of 0 disables the failure-record reserve");

        _select(_chain);

        PluginRepo repo = PluginRepo(_chain.crossChainRepo);
        _requireInstallableRepo(repo);

        // Resolved as "latest" on the HUB only — always the first chain through
        // here, prepared before any satellite — then that exact build is
        // demanded everywhere else. Each chain has its own repo with its own
        // publishing history, so asking each for "latest" independently puts
        // different builds on the two ends of a lane whenever one chain is
        // ahead. A satellite whose repo lacks the build reverts here.
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
        bytes memory data = CrossChainControllerSetup(version.pluginSetup)
            .encodeInstallationParameters(DEDICATED_EXECUTOR, _chain.dao, minFailedMessageGas);

        _broadcast();
        IPluginSetup.PreparedSetupData memory prepared;
        (plugin, prepared) = PluginSetupProcessor(_chain.psp)
            .prepareInstallation(
                _chain.dao,
                PluginSetupProcessor.PrepareInstallationParams({
                    pluginSetupRef: PluginSetupRef({ versionTag: version.tag, pluginSetupRepo: repo }),
                    data: data
                })
            );
        vm.stopBroadcast();

        require(prepared.helpers.length == 1, "unexpected helper count from CrossChainControllerSetup");
        _chain.controller = plugin;
        _chain.executor = prepared.helpers[0];

        PendingController storage pending = pendingControllers[_chain.chainId];
        delete pendingControllers[_chain.chainId];
        pending.repo = repo;
        pending.tag = version.tag;
        pending.helpersHash = hashHelpers(prepared.helpers);
        for (uint256 i = 0; i < prepared.permissions.length; i++) {
            pending.permissions.push(prepared.permissions[i]);
        }

        console.log("[3] controller prepared", plugin);
        console.log("    executor (owner = controller)", prepared.helpers[0]);
    }

    /// @notice Applies a prepared controller install onto its DAO.
    /// @dev Three actions, executed AS the DAO: grant the PSP `ROOT`, apply,
    ///      revoke it again. `PluginSetupProcessor._canApply` short-circuits on
    ///      `msg.sender == _dao`, so no `APPLY_INSTALLATION_PERMISSION` grant is
    ///      needed, and the PSP holds `ROOT` for one transaction and not a block
    ///      longer. `allowFailureMap` is zero, so a failed apply reverts the
    ///      whole `DAO.execute` and the pending prepare survives on chain — the
    ///      same apply can be re-sent.
    function _applyController(ChainCfg storage _chain) internal {
        _select(_chain);

        PendingController storage pending = pendingControllers[_chain.chainId];

        Action[] memory actions = new Action[](3);
        actions[0].to = _chain.dao;
        actions[0].data = abi.encodeCall(PermissionManager.grant, (_chain.dao, _chain.psp, ROOT_PERMISSION_ID));
        actions[1].to = _chain.psp;
        actions[1].data = abi.encodeCall(
            PluginSetupProcessor.applyInstallation,
            (
                _chain.dao,
                PluginSetupProcessor.ApplyInstallationParams({
                    pluginSetupRef: PluginSetupRef({ versionTag: pending.tag, pluginSetupRepo: pending.repo }),
                    plugin: _chain.controller,
                    permissions: pending.permissions,
                    helpersHash: pending.helpersHash
                })
            )
        );
        actions[2].to = _chain.dao;
        actions[2].data = abi.encodeCall(PermissionManager.revoke, (_chain.dao, _chain.psp, ROOT_PERMISSION_ID));

        _broadcast();
        IExecutor(_chain.dao).execute(bytes32(0), actions, 0);
        vm.stopBroadcast();

        console.log("[3] controller installed on", _chain.chainId);
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

    /// @notice Deploys every adapter, then wires every satellite lane.
    /// @dev Hub-and-spoke: the hub adapter trusts every satellite controller,
    ///      and each satellite adapter trusts only the hub. Satellites never
    ///      talk to each other.
    ///
    ///      The hub's own routing is deliberately absent. `updateConfig` is a
    ///      DAO action gated by `MANAGE_CONTROLLER_CONFIG`, which the hub DAO
    ///      only receives when `installCrosschain()` applies the prepared
    ///      install — so `_routeHub` runs there, right after the apply.
    ///      `_assertLanesWired` reads only adapter constructor state and needs
    ///      no hub permission, so it runs in full here.
    function _deployAdaptersAndRoute() internal {
        _deployHubAdapter();
        for (uint256 i = 0; i < satellites.length; i++) {
            _deploySatelliteAdapter(i);
        }

        for (uint256 i = 0; i < satellites.length; i++) {
            _routeSatellite(i);
        }

        _assertLanesWired();
    }

    /// @notice Reads every lane back off-chain, both halves, both directions.
    /// @dev The two halves of a lane are not equally forgiving. `chainToAdapter`
    ///      is controller storage a governed DAO can rewrite with `updateConfig`.
    ///      `trustedRemote` is set in the adapter's CONSTRUCTOR and has no setter
    ///      — get it wrong and the only repair is a replacement adapter on both
    ///      chains plus a governance round on each, after the deployer's
    ///      authority is already gone.
    ///
    ///      So the immutable half is the one worth proving, and it was the half
    ///      nothing checked. The failure it prevents is specifically quiet:
    ///      passing a `.dao` where a `.controller` belongs, or the remote
    ///      ADAPTER where the remote CONTROLLER belongs, deploys and routes
    ///      without complaint, and every inbound message then reverts
    ///      `REMOTE_NOT_TRUSTED` — invisible until the first veto fails to
    ///      arrive.
    ///
    ///      The remote is the remote CONTROLLER, not its adapter, because
    ///      `sendMessage` runs under `delegatecall` from the controller, so the
    ///      bridge attributes the message to the controller's address.
    function _assertLanesWired() private {
        _select(hub);
        require(
            BaseAdapter(hub.adapter).CROSS_CHAIN_CONTROLLER() == hub.controller,
            "hub adapter points at the wrong controller"
        );
        for (uint256 i = 0; i < satellites.length; i++) {
            require(
                BaseAdapter(hub.adapter).trustedRemote(satellites[i].chainId) == satellites[i].controller,
                "hub adapter does not trust the satellite CONTROLLER for this lane (constructor-only: not repairable after handover)"
            );
        }

        for (uint256 i = 0; i < satellites.length; i++) {
            _select(satellites[i]);
            require(
                BaseAdapter(satellites[i].adapter).CROSS_CHAIN_CONTROLLER() == satellites[i].controller,
                "satellite adapter points at the wrong controller"
            );
            require(
                BaseAdapter(satellites[i].adapter).trustedRemote(hub.chainId) == hub.controller,
                "satellite adapter does not trust the hub CONTROLLER (constructor-only: not repairable after handover)"
            );
            _requireMapsChain(satellites[i].adapter, hub.chainId);
        }

        _select(hub);
        for (uint256 i = 0; i < satellites.length; i++) {
            _requireMapsChain(hub.adapter, satellites[i].chainId);
        }

        console.log("[4] lanes verified: trusted remotes and chain-id mappings agree on both sides");
    }

    /// @dev Asks the deployed adapter, rather than trusting {_isTestnet} to agree
    ///      with `TestnetCCIPAdapter`'s table. Those are two hand-maintained lists
    ///      in different files, and only one of them is consulted when choosing
    ///      which class to construct: a chain in {_isTestnet} but absent from the
    ///      subclass's table — or a chain in neither, deployed as a production
    ///      `CCIPAdapter` whose map is mainnet-only — produces an adapter that
    ///      reverts `UNKNOWN_CHAIN_ID` on every send over that lane. The
    ///      deployment completes; the lane never carries a message.
    ///
    ///      One `staticcall` per lane settles it against the bytecode actually
    ///      deployed, which no amount of list-comparing can.
    function _requireMapsChain(address _adapter, uint256 _chainId) private view {
        try IBaseAdapter(_adapter).toNativeChainId(_chainId) returns (uint256 native) {
            require(native != 0, "adapter maps this chain id to a zero selector");
        } catch {
            revert(
                "adapter cannot map a chain id it must serve: the deployed adapter class has no selector for this lane, so every send over it would revert"
            );
        }
    }

    function _deployHubAdapter() private {
        _select(hub);

        BaseAdapter.TrustedRemoteConfig[] memory trusted = new BaseAdapter.TrustedRemoteConfig[](satellites.length);
        for (uint256 i = 0; i < satellites.length; i++) {
            require(satellites[i].controller != address(0), "satellite controller missing: install controllers first");
            trusted[i] = BaseAdapter.TrustedRemoteConfig({
                standardChainId: satellites[i].chainId, trustedRemote: satellites[i].controller
            });
        }

        _broadcast();
        hub.adapter = _newAdapter(hub, trusted);
        vm.stopBroadcast();
        console.log("[4] hub adapter", hub.adapter);
    }

    function _deploySatelliteAdapter(uint256 _i) private {
        _select(satellites[_i]);
        require(hub.controller != address(0), "hub controller missing: install controllers first");

        BaseAdapter.TrustedRemoteConfig[] memory trusted = new BaseAdapter.TrustedRemoteConfig[](1);
        trusted[0] = BaseAdapter.TrustedRemoteConfig({ standardChainId: hub.chainId, trustedRemote: hub.controller });

        _broadcast();
        satellites[_i].adapter = _newAdapter(satellites[_i], trusted);
        vm.stopBroadcast();
        console.log("[4] satellite adapter", satellites[_i].adapter);
    }

    /// @notice The adapter for the chain in scope.
    /// @dev `CCIPAdapter`'s chain table is mainnet-only, and that is deliberate:
    ///      it is audited production source and testnet entries do not belong in
    ///      it. `TestnetCCIPAdapter` (in `script/`, outside audit scope)
    ///      overrides just the table, in both directions, for the testnets.
    ///
    ///      The kit picks between them so a consumer writes no adapter code
    ///      either way. The honest cost: a testnet rehearsal exercises the
    ///      subclass, not the contract that ships. Everything security-relevant
    ///      -- trusted-remote checks, the send and receive paths, fee handling --
    ///      is the production contract regardless; only the id/selector lookup
    ///      differs.
    function _newAdapter(ChainCfg storage _chain, BaseAdapter.TrustedRemoteConfig[] memory _trusted)
        private
        returns (address)
    {
        // CREATE2, and this is not a preference. `forge script` runs the
        // deployer's nonce as ONE counter across every fork -- measured: chain A
        // gets 0, 2, 6, chain B gets 1, 4, 7 -- while the broadcast replay
        // executes each chain's transactions against that chain's OWN nonce,
        // which starts wherever the real chain is. So a plain `new` produces an
        // address in-script that the replay never reproduces, and the
        // `updateConfig` that references it fails `HAS_NO_CODE` on a deployment
        // that is otherwise correct.
        //
        // Only contracts the SCRIPT deploys are affected. The DAO and the
        // controller proxy are CREATE'd by the `DAOFactory` and the PSP, whose
        // nonces are real per-chain state and replay identically -- which is
        // why the adapters were the only casualty.
        //
        // CREATE2 removes the nonce from the address entirely. The salt binds
        // the chain and the controller, so a re-run after a failed deployment
        // lands somewhere new rather than colliding.
        bytes32 salt = keccak256(abi.encode(_chain.chainId, _chain.controller));

        if (_isTestnet(_chain.chainId)) {
            return address(
                new TestnetCCIPAdapter{
                    salt: salt
                }(_chain.controller, _chain.ccipRouter, _chain.ccipFeeToken, _trusted)
            );
        }
        return
            address(new CCIPAdapter{ salt: salt }(_chain.controller, _chain.ccipRouter, _chain.ccipFeeToken, _trusted));
    }

    /// @dev Must match `TestnetCCIPAdapter`'s table. A chain listed here but not
    ///      there gets an adapter that reverts `UNKNOWN_CHAIN_ID` on every lane.
    function _isTestnet(uint256 _chainId) private pure returns (bool) {
        return _chainId == 11_155_111 || _chainId == 84_532 || _chainId == 421_614;
    }

    function _routeHub() private {
        uint256[] memory chainIds = new uint256[](satellites.length);
        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](satellites.length);

        for (uint256 i = 0; i < satellites.length; i++) {
            chainIds[i] = satellites[i].chainId;
            configs[i] =
                ICrossChainController.ChainConfig({ localAdapter: hub.adapter, remoteAdapter: satellites[i].adapter });
        }

        _updateConfig(hub, chainIds, configs);
    }

    function _routeSatellite(uint256 _i) private {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = hub.chainId;

        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] =
            ICrossChainController.ChainConfig({ localAdapter: satellites[_i].adapter, remoteAdapter: hub.adapter });

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
    /// @dev Plural on purpose: real governance is often several contracts, and
    ///      one declaration can pass while another holder's grant silently
    ///      failed.
    ///
    ///      **Declare only UNCONDITIONAL holders.** OSx `GrantWithCondition`
    ///      permissions cannot be verified generically — `hasPermission` runs
    ///      the condition against the calldata you pass, and the kit has no idea
    ///      what call a given governor would legitimately make, so a
    ///      conditionally-granted address reads as unauthorised here even when
    ///      it is correctly configured. A staged proposal processor scoped by a
    ///      selector condition is the usual case.
    ///
    ///      That is a real limit, not an oversight: what this check can prove is
    ///      that the DAO is not frozen, which needs at least one address able to
    ///      act without qualification. Conditional grants are for the consumer's
    ///      own tests, which know what those conditions permit.
    ///      Two addresses are rejected outright. `address(0)` because a hook that
    ///      declares an unset config field would otherwise be asking
    ///      `_assertGovernable` a question about the zero address — and OSx will
    ///      happily report a grant against it, so the check would pass on a DAO
    ///      nothing can act as. And `deployer`, because phase 6 revokes exactly
    ///      that address: declaring it means the governability proof is made
    ///      against an authority the very next phase destroys.
    function _addGovernor(ChainCfg storage _chain, address _governor) internal {
        require(_governor != address(0), "governor is the zero address: a DAO governed by nobody is not governed");
        require(
            _governor != deployer,
            "governor is the deployer, whose EXECUTE the handover revokes: declare the governance that outlives the run"
        );
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

        // Roster ENTRIES, not just its length. OSx `Addresslist._addAddresses`
        // rejects duplicates but accepts `address(0)` and counts it toward
        // `addresslistLength`, so a placeholder left in a config file raises the
        // effective threshold without raising the number of signers who can
        // ever approve. A 2-of-["0xAlice", "0x0"] multisig installs cleanly, is
        // granted EXECUTE, satisfies `_assertGovernable` — which asks whether the
        // plugin HOLDS the permission, not whether its quorum is reachable — and
        // leaves the chain's controller permanently unmanageable once the
        // handover lands.
        for (uint256 i = 0; i < _chain.members.length; i++) {
            require(
                _chain.members[i] != address(0),
                "governance roster contains the zero address: quorum would be unreachable"
            );
        }

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
                DAO(payable(_chain.dao)).hasPermission(_chain.dao, _chain.governors[i], EXECUTE_PERMISSION_ID, ""),
                "declared governor cannot execute as the DAO"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Phase 6 — handover
    // -------------------------------------------------------------------------

    /// @notice Takes `EXECUTE` away from the deployer on every satellite.
    /// @dev MUST be last: every phase above is authorised by this permission.
    ///      Irreversible, so the governability check runs once more immediately
    ///      before it rather than being trusted from phase 5.
    ///
    ///      Self-revoking, and safe: the deployer executes it AS the DAO, and the
    ///      DAO holds `ROOT` on itself, so this is the deployer's last act with
    ///      the authority it is giving up. A failed transaction leaves the
    ///      permission in place and can be retried.
    ///
    ///      The hub is deliberately absent: the deployer's `EXECUTE` there is
    ///      the consumer's working authority for everything that follows the
    ///      install — its own governance, grants against final addresses — and
    ///      only the consumer knows when that work is done. The kit revokes
    ///      nothing on the hub.
    function _handOver() internal {
        for (uint256 i = 0; i < satellites.length; i++) {
            _revokeDeployer(satellites[i]);
        }
    }

    function _revokeDeployer(ChainCfg storage _chain) private {
        _select(_chain);
        _assertGovernable(_chain);

        _broadcast();
        _daoAction(_chain, abi.encodeCall(PermissionManager.revoke, (_chain.dao, deployer, EXECUTE_PERMISSION_ID)));
        vm.stopBroadcast();
        console.log("[6] deployer EXECUTE revoked on", _chain.chainId);
    }

    // -------------------------------------------------------------------------
    // Entry points
    // -------------------------------------------------------------------------

    /// @notice Step one of three: resolve the signer, load the topology, create
    ///         the forks, and leave the HUB fork selected.
    /// @dev The consumer sequence is
    ///        `initCrosschain → create the hub DAO → setUpCrosschain →
    ///         installCrosschain → hub governance → hand over`,
    ///      and the hub DAO must be created on the fork this call leaves
    ///      selected — a DAO on any other fork is a DAO on the wrong chain,
    ///      which `setUpCrosschain()`'s preconditions reject as codeless.
    ///
    ///      `_deployerKey` accepts either signing path. Pass
    ///      `vm.envOr("PRIVATE_KEY", uint256(0))` from your `run()`: a non-zero
    ///      value broadcasts with that key, zero defers to whatever forge's own
    ///      `--account` / `--ledger` / `--private-key` resolved. A keystore or a
    ///      hardware wallet is the better habit — a plaintext key in the
    ///      environment is readable by anything running as you, and leaves no
    ///      record of which key signed — but CI usually has a secret and not a
    ///      keystore, and refusing that just pushes people to `--private-key`
    ///      on the command line, where the key is visible in `ps`.
    ///
    ///      The precedence is the sharp edge: a stale `PRIVATE_KEY` left in a
    ///      shell silently wins over `--account`. The kit cannot detect which
    ///      flags forge was given, so it prints the resolved signer and its
    ///      source before anything is broadcast — see {_reportSigner}.
    function initCrosschain(uint256 _deployerKey) public {
        deployerKey = _deployerKey;
        deployer = _resolveDeployer();
        _reportSigner();

        _loadTopology();
        _createForks();
        _select(hub);
    }

    /// @notice Step two: everything that does not need to act as the hub DAO.
    ///         Prepares the hub controller, then builds every satellite end to
    ///         end — DAO, controller, adapter, routing, governance, handover —
    ///         and deploys and cross-checks the hub adapter.
    /// @dev The preconditions run HERE, not only at install. This call hands
    ///      satellites over to their governance and burns ENS subdomains, which
    ///      are claimed once per registrar and never released — validating the
    ///      hub only at install would mean discovering a typo'd `hub.dao` after
    ///      the satellites are already unrecoverable.
    ///
    ///      Exits standing on a satellite fork; `installCrosschain()` selects
    ///      the hub again itself.
    function setUpCrosschain() public {
        require(satellites.length > 0, "no satellites configured: a single-chain DAO does not need this kit");
        require(hub.controller == address(0), "setUpCrosschain already ran");

        _select(hub);
        _requireActionableHub();

        _prepareController(hub);

        _createSatelliteDaos();
        _installControllers();

        _deployAdaptersAndRoute();

        _configureGovernance();
        _handOver();
    }

    /// @notice Step three: applies the prepared controller install onto the hub
    ///         DAO and wires the hub's lanes.
    /// @dev Re-checks the preconditions — they are cheap views, and the
    ///      consumer may have revoked something between the two calls.
    ///
    ///      In-process, a revert here is recoverable: the kit passes
    ///      `allowFailureMap = 0`, so the failed `DAO.execute` is atomic and
    ///      the pending prepare survives on chain. Across processes it is NOT
    ///      "just re-run the script" — see the README's recovery section.
    function installCrosschain() public {
        // Select before ANY read: setUpCrosschain() exits standing on a
        // satellite fork, and `hasPermission` against an address with no code
        // on the wrong chain reverts uninformatively — or, worse, an address
        // collision answers with another chain's state.
        _select(hub);

        require(
            hub.controller != address(0),
            "call setUpCrosschain first: installCrosschain only applies the install it prepared"
        );
        _requireActionableHub();

        // OSx would also refuse a second apply, but deep inside the PSP with a
        // custom error naming a setup id. Asking `states` directly turns "you
        // already installed this" into a sentence, before any broadcast.
        (, bytes32 appliedSetupId) =
            PluginSetupProcessor(hub.psp).states(keccak256(abi.encode(hub.dao, hub.controller)));
        require(appliedSetupId == bytes32(0), "this controller is already installed on this DAO");

        _applyController(hub);
        _routeHub();
        _assertHubRouted();

        _report();
    }

    /// @dev The preconditions the consumer owes the kit on the hub DAO, checked
    ///      while standing on the hub fork. The structural guarantee the kit
    ///      used to have — it created every DAO itself — is gone on the hub, so
    ///      nothing about how the consumer built theirs is assumed.
    function _requireActionableHub() private view {
        require(hub.dao != address(0), "hub.dao is not set: create the hub DAO after initCrosschain()");
        require(
            hub.dao.code.length > 0,
            "hub.dao has no code on the hub chain: it was created on another fork, or not at all"
        );
        _assertDeployerBootstrapped(hub);
        // `_applyController`'s first action is a `grant` executed AS the DAO,
        // and `PermissionManager.grant` is `auth(ROOT)`. Every `DAOFactory` DAO
        // holds ROOT on itself, but the premise of these checks is not trusting
        // how the consumer built theirs.
        require(
            DAO(payable(hub.dao)).hasPermission(hub.dao, hub.dao, ROOT_PERMISSION_ID, ""),
            "the hub DAO does not hold ROOT on itself: the kit acts BY executing grants as the DAO, which OSx gates on ROOT"
        );
    }

    /// @dev Asserts what `_routeHub` just WROTE by reading it back off the
    ///      controller — deliberately not `_assertLanesWired`, which reads
    ///      adapter constructor state and would stay green even if the routing
    ///      write had gone nowhere.
    function _assertHubRouted() private {
        _select(hub);
        for (uint256 i = 0; i < satellites.length; i++) {
            (address local, address remote) =
                CrossChainController(payable(hub.controller)).chainToAdapter(satellites[i].chainId);
            require(local == hub.adapter, "hub lane routed to the wrong local adapter");
            require(remote == satellites[i].adapter, "hub lane routed to the wrong remote adapter");
        }
        console.log("[install] hub lanes routed and read back:", satellites.length);
    }

    /// @dev Printed before the first broadcast, because the kit cannot tell
    ///      whether forge was given `--account`: if a stale `PRIVATE_KEY` is
    ///      sitting in the environment it wins, and the only way an operator
    ///      catches that is by seeing the address. Deployments are irreversible;
    ///      the wrong signer is worth one line of output.
    function _reportSigner() private view {
        console.log("Signing as:", deployer);
        console.log(
            deployerKey == 0
                ? "  source: forge (--account / --ledger / --private-key)"
                : "  source: PRIVATE_KEY from the environment"
        );
    }

    /// @notice Gas the controller withholds so a failed inbound message is
    ///         recorded as `Delivered` rather than reverting the whole delivery.
    /// @dev Never zero: a zero reserve lets an out-of-gas payload revert the
    ///      delivery, recording nothing, and the message is then unreachable by
    ///      both `retryMessage` and `cancelMessage`.
    uint256 internal minFailedMessageGas = 45_000;

    /// @dev The run's only output. Capture it — the kit itself writes no files.
    ///
    ///      Virtual because a consumer whose existing tooling reads an address
    ///      book has to get one from somewhere, and after every phase has
    ///      succeeded is the only honest moment to write it. The kit stays
    ///      file-free by default; override, call `super._report()`, and persist
    ///      whatever the verifiers need. Guard that write with
    ///      `vm.isContext(VmSafe.ForgeContext.ScriptDryRun)` — a dry run reaches
    ///      here too, and would otherwise overwrite the record of the live
    ///      deployment with addresses that were never broadcast.
    function _report() internal virtual {
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
