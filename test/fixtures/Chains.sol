// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { ChainIdRegistry } from "@src/registry/ChainIdRegistry.sol";

/// @title ChainsFixture
/// @notice Chain ids and CCIP selectors, read from `test/fixtures/chains.json`.
/// @dev These values used to be `src/lib/ChainIds.sol` and
///      `src/adapters/CCIP/CCIPChainIds.sol`, compiled into every adapter. The
///      adapters now resolve chain ids through a `ChainIdRegistry` seeded from
///      config, so the table is test and config data and the contracts carry
///      none of it.
///
///      The payoff beyond relocation is {seedChain}: a suite seeds its registry
///      from the same file the deploy kit's topology is written against, so the
///      tests exercise the read-pairs-from-config path production uses rather
///      than a Solidity table only the tests can see.
///
///      Lookups are SCALAR `parseJsonUint` reads, one path at a time. The
///      array-valued JSON cheatcodes generate ABI decoders heavy enough to
///      overflow the stack without `via_ir`, which this repo does not enable --
///      see the same note on `CrossChainDeploy._loadTopologyFromJson`.
///
///      `readFile` is `view`, so callers can stay `view` and read per lookup;
///      caching is not worth the state at test scale. Names are JSON keys, so a
///      typo is a revert at run time rather than a compile error -- the one
///      thing given up by moving off Solidity constants.
abstract contract ChainsFixture is Test {
    string internal constant CHAINS_JSON = "test/fixtures/chains.json";

    /// @notice The standard (EVM) chain id of a named chain.
    /// @param _name The JSON key, e.g. `"ethereum"` or `"baseSepolia"`.
    function chainId(string memory _name) internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(CHAINS_JSON), string.concat(".", _name, ".chainId"));
    }

    /// @notice The CCIP chain selector of a named chain.
    /// @param _name The JSON key, e.g. `"ethereum"` or `"baseSepolia"`.
    function ccipSelector(string memory _name) internal view returns (uint64) {
        return uint64(vm.parseJsonUint(vm.readFile(CHAINS_JSON), string.concat(".", _name, ".ccipSelector")));
    }

    /// @notice Writes a named chain's pair into a registry.
    /// @dev The caller must already hold `MANAGE_CHAIN_ID_REGISTRY_PERMISSION`
    ///      on `_registry` in its DAO -- this helper does not prank.
    function seedChain(ChainIdRegistry _registry, string memory _name) internal {
        _registry.setChainIdPair(chainId(_name), ccipSelector(_name));
    }

    /// @notice Writes an arbitrary pair, for the cases a real chain cannot
    ///         express -- an unmapped lane, or a selector wider than `uint64`.
    function seedPair(ChainIdRegistry _registry, uint256 _standardChainId, uint256 _nativeChainId) internal {
        _registry.setChainIdPair(_standardChainId, _nativeChainId);
    }
}
