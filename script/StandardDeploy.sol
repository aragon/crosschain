// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainDeploy } from "./CrossChainDeploy.sol";

/// @title StandardDeploy
/// @notice A complete deployment for a DAO governed by a multisig on every
///         chain. Config only — no Solidity to write.
/// @dev This is the whole point of the kit having defaults. A project whose
///      governance is "a multisig here and a multisig on each satellite" runs
///      this against a topology file and writes nothing:
///
///        DEPLOY_CONFIG=deploy/my-dao.json \
///          forge script StandardDeploy --broadcast --account <keystore>
///
///      Anything else subclasses `CrossChainDeploy` and overrides
///      `_configureHub`. The satellites can still take the default.
///
///      The signer is resolved by forge's own `--account` / `--ledger` flags.
///      Deliberately never an environment variable: a plaintext key in a shell
///      is visible to every process, lands in history, and leaves no record of
///      which key signed a deployment.
/// @custom:security-contact sirt@aragon.org
contract StandardDeploy is CrossChainDeploy {
    function _loadTopology() internal override {
        _loadTopologyFromJson(vm.envOr("DEPLOY_CONFIG", string("deploy/topology.json")));
    }

    function _configureHub() internal override {
        _installMultisigGovernance(hub);
    }
}
