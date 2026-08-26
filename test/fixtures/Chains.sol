// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { ChainIdRegistry } from "@src/registry/ChainIdRegistry.sol";

/// @title ChainsFixture
/// @notice Chain ids and CCIP selectors, read from `test/fixtures/chains.json`.
/// @dev Lookups are scalar `parseJsonUint` reads, one path at a time: the
///      array-valued JSON cheatcodes overflow the stack without `via_ir`.
///      Names are JSON keys, so a typo reverts at run time.
abstract contract ChainsFixture is Test {
    string internal constant CHAINS_JSON = "test/fixtures/chains.json";

    /// @notice The standard (EVM) chain id of a named chain, e.g. `"baseSepolia"`.
    function chainId(string memory _name) internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(CHAINS_JSON), string.concat(".", _name, ".chainId"));
    }

    /// @notice The CCIP chain selector of a named chain.
    function ccipSelector(string memory _name) internal view returns (uint64) {
        return uint64(vm.parseJsonUint(vm.readFile(CHAINS_JSON), string.concat(".", _name, ".ccipSelector")));
    }

    /// @notice Writes a named chain's pair into a registry.
    /// @dev Does not prank: the caller must already hold the manage permission.
    function seedChain(ChainIdRegistry _registry, string memory _name) internal {
        _registry.setChainIdPair(chainId(_name), ccipSelector(_name));
    }

    /// @notice Writes an arbitrary pair, for values no real chain carries.
    function seedPair(ChainIdRegistry _registry, uint256 _standardChainId, uint256 _nativeChainId) internal {
        _registry.setChainIdPair(_standardChainId, _nativeChainId);
    }
}
