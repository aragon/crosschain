// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { CrossChainDeploy } from "../../script/CrossChainDeploy.sol";
import { ChainIds } from "@src/lib/ChainIds.sol";

/// @notice Fills the topology from values the test sets, rather than from a file.
/// @dev Also exposes the internals the kit keeps to itself, so the assertions can
///      reach them without widening the kit's own surface.
contract KitHarness is CrossChainDeploy {
    uint256[] internal presetForks;
    uint256[] internal chainIds;
    string[] internal rpcs;

    function addChain(uint256 _chainId, string memory _rpc) external {
        chainIds.push(_chainId);
        rpcs.push(_rpc);
    }

    /// @dev Hub first, then satellites in order.
    function presetFork(uint256 _forkId) external {
        presetForks.push(_forkId);
    }

    function _loadTopology() internal override {
        hub.chainId = chainIds[0];
        hub.rpc = rpcs[0];
        for (uint256 i = 1; i < chainIds.length; i++) {
            satellites.push();
            satellites[i - 1].chainId = chainIds[i];
            satellites[i - 1].rpc = rpcs[i];
        }
    }

    /// @dev Reuses forks the test already made, so the run and the assertions
    ///      share the same state.
    function _createForks() internal override {
        hub.forkId = presetForks[0];
        for (uint256 i = 0; i < satellites.length; i++) {
            satellites[i].forkId = presetForks[i + 1];
        }
    }

    // --- exposed for the tests ---

    function loadTopology() external {
        _loadTopology();
    }

    function createForks() external {
        _createForks();
    }

    function selectHub() external {
        _select(hub);
    }

    function selectSatellite(uint256 _i) external {
        _select(satellites[_i]);
    }

    function hubChainId() external view returns (uint256) {
        return hub.chainId;
    }

    function satelliteChainId(uint256 _i) external view returns (uint256) {
        return satellites[_i].chainId;
    }

    /// @dev Corrupts the recorded chain id so the guard can be exercised without
    ///      needing an RPC that lies about which chain it is.
    function corruptHubChainId(uint256 _wrong) external {
        hub.chainId = _wrong;
    }
}

/// @notice Fork creation and the chain-id guard.
/// @dev Skips without RPCs. Public endpoints are fine — nothing here reads
///      historical state.
contract CrossChainDeployTest is Test {
    KitHarness internal kit;

    uint256 internal hubFork;
    uint256 internal satFork;

    function setUp() public {
        vm.skip(bytes(vm.envOr("SEPOLIA_RPC_URL", string(""))).length == 0);
        vm.skip(bytes(vm.envOr("BASE_SEPOLIA_RPC_URL", string(""))).length == 0);

        // `createFork` does not select, so the harness below is still built on
        // the base state — which is what lets it survive every later switch
        // without `vm.makePersistent`. See the note on CrossChainDeploy.
        hubFork = vm.createFork(vm.envString("SEPOLIA_RPC_URL"));
        satFork = vm.createFork(vm.envString("BASE_SEPOLIA_RPC_URL"));

        kit = new KitHarness();
        kit.addChain(ChainIds.SEPOLIA, "unused-preset");
        kit.addChain(ChainIds.BASE_SEPOLIA, "unused-preset");
        kit.presetFork(hubFork);
        kit.presetFork(satFork);
        kit.loadTopology();
        kit.createForks();
    }

    function test_topologyIsHubPlusSatellites() public view {
        assertEq(kit.chainCount(), 2, "hub + one satellite");
        assertEq(kit.hubChainId(), ChainIds.SEPOLIA, "hub");
        assertEq(kit.satelliteChainId(0), ChainIds.BASE_SEPOLIA, "satellite");
    }

    function test_selectLandsOnTheConfiguredChain() public {
        kit.selectHub();
        assertEq(block.chainid, ChainIds.SEPOLIA, "hub fork");

        kit.selectSatellite(0);
        assertEq(block.chainid, ChainIds.BASE_SEPOLIA, "satellite fork");

        // Back again: the harness is still reachable after a round trip, which
        // is the property the construction order buys.
        kit.selectHub();
        assertEq(block.chainid, ChainIds.SEPOLIA, "returned to hub");
    }

    /// @notice The guard that makes a wrong RPC a failed run rather than a
    ///         permanently mis-keyed lane.
    function test_selectRejectsAForkThatIsNotTheConfiguredChain() public {
        kit.corruptHubChainId(ChainIds.ETHEREUM);

        vm.expectRevert(bytes("RPC does not match the configured chain id"));
        kit.selectHub();
    }
}
