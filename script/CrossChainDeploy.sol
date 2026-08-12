// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Script, console } from "forge-std/Script.sol";

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
}
