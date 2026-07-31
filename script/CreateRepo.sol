// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { Script, console as console } from "forge-std/Script.sol";

import { IPluginSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import { PluginRepo } from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import { PluginRepoFactory } from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";

import { CrossChainControllerSetup } from "@src/CrossChainControllerSetup.sol";
import { CrossChainController } from "@src/CrossChainController.sol";

/// @title CreateRepo
/// @notice Deploys `CrossChainControllerSetup` inside PluginRepoFactory
contract CreateRepo is Script {
    address deployer;
    string pluginEnsSubdomain;
    address pluginRepoMaintainerAddress;
    PluginRepoFactory pluginRepoFactory;
    bytes releaseMetadataUri;
    bytes buildMetadataUri;

    // Artifacts
    PluginRepo myPluginRepo;
    address pluginSetup;

    modifier broadcast() {
        uint256 privKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privKey);

        deployer = vm.addr(privKey);
        console.log("General");
        console.log("- Deploying from:   ", deployer);
        console.log("- Chain ID:         ", block.chainid);
        console.log("");

        _;

        vm.stopBroadcast();
    }

    function setUp() public {
        // Pick the contract addresses from
        // https://github.com/aragon/osx/blob/main/packages/artifacts/src/addresses.json

        // Prepare the OSx factories for the current network
        pluginRepoFactory = PluginRepoFactory(vm.envAddress("PLUGIN_REPO_FACTORY_ADDRESS"));
        vm.label(address(pluginRepoFactory), "PluginRepoFactory");

        // Read the rest of environment variables
        pluginEnsSubdomain = vm.envOr("PLUGIN_ENS_SUBDOMAIN", string(""));

        // Using a random subdomain if empty
        if (bytes(pluginEnsSubdomain).length == 0) {
            pluginEnsSubdomain = string.concat("cross-chain-controller", vm.toString(block.timestamp));
        }

        pluginRepoMaintainerAddress = vm.envAddress("PLUGIN_REPO_MAINTAINER_ADDRESS");
        vm.label(pluginRepoMaintainerAddress, "Maintainer");

        releaseMetadataUri = vm.envOr("RELEASE_METADATA_URI", bytes(" "));
        buildMetadataUri = vm.envOr("BUILD_METADATA_URI", bytes(" "));
    }

    function run() public broadcast {
        // Deploys the `CrossChainController` implementation in its constructor.
        pluginSetup = address(new CrossChainControllerSetup(address(new CrossChainController())));

        myPluginRepo = pluginRepoFactory.createPluginRepoWithFirstVersion(
            pluginEnsSubdomain, pluginSetup, pluginRepoMaintainerAddress, releaseMetadataUri, buildMetadataUri
        );

        console.log("PluginRepo:                  ", address(myPluginRepo));
        console.log("CrossChainControllerSetup:   ", address(pluginSetup));
        console.log("CrossChainController impl:   ", IPluginSetup(pluginSetup).implementation());
        console.log("Maintainer:                  ", pluginRepoMaintainerAddress);
        console.log("Subdomain:                   ", pluginEnsSubdomain);
    }
}
