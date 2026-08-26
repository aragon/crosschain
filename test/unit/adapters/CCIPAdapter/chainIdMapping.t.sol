// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapterBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";

/// @notice Tests the standard <-> CCIP-native chain id mapping
///         (`toNativeChainId` / `fromNativeChainId`), which `BaseAdapter`
///         resolves off the bound `ChainIdRegistry`.
/// @dev The registry answers `0` for an unmapped id; the adapter turns that into
///      a revert, because returning it would address chain zero rather than
///      fail. Both directions are checked for that here -- what the registry
///      itself stores is `ChainIdRegistry.t.sol`'s subject.
contract CCIPAdapterChainIdMappingTest is CCIPAdapterBase {
    function test_toNativeChainId_returnsConfiguredSelector() public view {
        assertEq(adapter.toNativeChainId(CHAIN_ETH_MAINNET), uint256(SEL_ETH_MAINNET));
    }

    function test_toNativeChainId_revertsForUnmappedChain() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_SEPOLIA));
        adapter.toNativeChainId(CHAIN_SEPOLIA);
    }

    function test_fromNativeChainId_isExactInverseOfToNativeChainId() public view {
        assertEq(adapter.fromNativeChainId(uint256(SEL_ETH_MAINNET)), CHAIN_ETH_MAINNET);
        assertEq(adapter.fromNativeChainId(uint256(SEL_BASE)), CHAIN_BASE);
        assertEq(adapter.fromNativeChainId(uint256(SEL_ARBITRUM_ONE)), CHAIN_ARBITRUM_ONE);
    }

    function test_fromNativeChainId_revertsForUnmappedSelector() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, uint256(SEL_SEPOLIA)));
        adapter.fromNativeChainId(uint256(SEL_SEPOLIA));
    }

    function test_roundTripsOverSeveralConfiguredChains() public view {
        uint256[3] memory chains = [CHAIN_ETH_MAINNET, CHAIN_BASE, CHAIN_ARBITRUM_ONE];
        for (uint256 i = 0; i < chains.length; i++) {
            assertEq(adapter.fromNativeChainId(adapter.toNativeChainId(chains[i])), chains[i]);
        }
    }

    /// @dev The point of the registry: a chain the adapter could not serve at
    ///      deployment becomes serveable without replacing the adapter.
    function test_seedingANewChainMakesTheLaneResolvable_withoutANewAdapter() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_SEPOLIA));
        adapter.toNativeChainId(CHAIN_SEPOLIA);

        seedChain(registry, "sepolia");

        assertEq(adapter.toNativeChainId(CHAIN_SEPOLIA), uint256(SEL_SEPOLIA));
        assertEq(adapter.fromNativeChainId(uint256(SEL_SEPOLIA)), CHAIN_SEPOLIA);
    }

    /// @dev The other side of that: the same permission repoints a LIVE lane at
    ///      a different chain, and the adapter follows without notice. This is
    ///      the trust the registry hands the permission holder, asserted so it
    ///      cannot be lost track of.
    function test_repointingALiveLaneChangesWhereTheAdapterSends() public {
        assertEq(adapter.toNativeChainId(CHAIN_ETH_MAINNET), uint256(SEL_ETH_MAINNET));

        seedPair(registry, CHAIN_ETH_MAINNET, uint256(SEL_BASE));

        assertEq(adapter.toNativeChainId(CHAIN_ETH_MAINNET), uint256(SEL_BASE));
        // The retired reverse entry must not survive: mainnet's old selector
        // would otherwise still authenticate inbound messages.
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, uint256(SEL_ETH_MAINNET)));
        adapter.fromNativeChainId(uint256(SEL_ETH_MAINNET));
    }

    /// @dev Clearing a lane shuts it down in both directions at the adapter.
    function test_clearingALaneMakesTheAdapterRevertBothWays() public {
        seedPair(registry, CHAIN_BASE, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_BASE));
        adapter.toNativeChainId(CHAIN_BASE);

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, uint256(SEL_BASE)));
        adapter.fromNativeChainId(uint256(SEL_BASE));
    }
}
