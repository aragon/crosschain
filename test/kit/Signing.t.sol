// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { CrossChainDeploy } from "../../script/CrossChainDeploy.sol";

contract SigningProbe is CrossChainDeploy {
    function _loadTopology() internal override { }
    function _configureHub() internal override { }

    /// @dev The production path: no key, so forge's resolved sender signs.
    function probeForgeResolved() external {
        deployerKey = 0;
        _broadcast();
        vm.stopBroadcast();
    }

    function probeExplicitKey(uint256 _key) external {
        deployerKey = _key;
        _broadcast();
        vm.stopBroadcast();
    }

    function resolveWith(uint256 _key) external returns (address) {
        deployerKey = _key;
        return _resolveDeployer();
    }
}

/// @notice Both signing paths, and the seam a fork suite cannot reach.
/// @dev A fork suite always supplies a real key -- it needs a specific funded
///      address and must stay off `vm.setEnv`, which is process-global and races
///      concurrent tests. So the zero-key path, which is the one production
///      uses, is only reachable here.
contract SigningTest is Test {
    SigningProbe internal probe;

    function setUp() public {
        probe = new SigningProbe();
    }

    /// @notice `vm.startBroadcast(0)` reverts "private key cannot be 0", so a
    ///         zero key must branch to the no-argument form rather than being
    ///         passed through.
    function test_zeroKeyUsesForgeResolvedSender() public {
        probe.probeForgeResolved();
    }

    function test_explicitKeyBroadcastsWithIt() public {
        probe.probeExplicitKey(uint256(keccak256("signer")));
    }

    function test_zeroKeyResolvesTheCallerNotAddressZero() public {
        assertEq(probe.resolveWith(0), address(this), "zero means the sender forge resolved");
    }

    function test_explicitKeyResolvesThatKeysAddress() public {
        uint256 key = uint256(keccak256("signer"));
        assertEq(probe.resolveWith(key), vm.addr(key), "an explicit key addresses itself");
    }
}
