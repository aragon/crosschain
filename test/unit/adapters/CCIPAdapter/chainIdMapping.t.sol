// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapterBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";

/// @notice Tests `toNativeChainId` / `fromNativeChainId`, which `BaseAdapter`
///         resolves off the bound `ChainIdRegistry`.
/// @dev What the registry itself stores is `ChainIdRegistry.t.sol`'s subject;
///      this covers the adapter's revert-on-unmapped wrapper.
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

    /// @dev The point of the registry: no new adapter to serve a new chain.
    function test_seedingANewChainMakesTheLaneResolvable_withoutANewAdapter() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_SEPOLIA));
        adapter.toNativeChainId(CHAIN_SEPOLIA);

        seedChain(registry, "sepolia");

        assertEq(adapter.toNativeChainId(CHAIN_SEPOLIA), uint256(SEL_SEPOLIA));
        assertEq(adapter.fromNativeChainId(uint256(SEL_SEPOLIA)), CHAIN_SEPOLIA);
    }

    /// @dev The same permission repoints a LIVE lane, and the adapter follows
    ///      without notice. Asserted so the trust it hands the holder is visible.
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
