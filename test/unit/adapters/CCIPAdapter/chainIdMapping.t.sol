// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapterBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";

/// @notice Tests the standard <-> CCIP-native chain id mapping
///         (`toNativeChainId` / `fromNativeChainId`).
contract CCIPAdapterChainIdMappingTest is CCIPAdapterBase {
    function test_toNativeChainId_returnsConfiguredSelector() public view {
        assertEq(adapter.toNativeChainId(CHAIN_ETH_MAINNET), uint256(SEL_ETH_MAINNET));
    }

    function test_toNativeChainId_revertsForUnmappedChain() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, CHAIN_UNMAPPED));
        adapter.toNativeChainId(CHAIN_UNMAPPED);
    }

    function test_fromNativeChainId_isExactInverseOfToNativeChainId() public view {
        assertEq(adapter.fromNativeChainId(uint256(SEL_ETH_MAINNET)), CHAIN_ETH_MAINNET);
        assertEq(adapter.fromNativeChainId(uint256(SEL_BASE)), CHAIN_BASE);
        assertEq(adapter.fromNativeChainId(uint256(SEL_ARBITRUM_ONE)), CHAIN_ARBITRUM_ONE);
    }

    function test_fromNativeChainId_revertsForUnmappedSelector() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_NATIVE_CHAIN_ID.selector, uint256(SEL_UNMAPPED)));
        adapter.fromNativeChainId(uint256(SEL_UNMAPPED));
    }

    function test_roundTripsOverSeveralConfiguredChains() public view {
        uint256[3] memory chains = [CHAIN_ETH_MAINNET, CHAIN_BASE, CHAIN_ARBITRUM_ONE];
        for (uint256 i = 0; i < chains.length; i++) {
            assertEq(adapter.fromNativeChainId(adapter.toNativeChainId(chains[i])), chains[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Testnets
    //
    // Supported deliberately. Without them an adapter cannot be constructed on
    // a testnet at all -- `UNKNOWN_CHAIN_ID` on any lane -- so a project
    // rehearsing a deployment has to subclass the adapter and override this
    // table. That means the rehearsal exercises a DIFFERENT contract than
    // production, which is the one thing a rehearsal must not do.
    // -------------------------------------------------------------------------

    function test_toNativeChainId_mapsSupportedTestnets() public view {
        assertEq(adapter.toNativeChainId(CHAIN_SEPOLIA), uint256(SEL_SEPOLIA));
        assertEq(adapter.toNativeChainId(CHAIN_BASE_SEPOLIA), uint256(SEL_BASE_SEPOLIA));
        assertEq(adapter.toNativeChainId(CHAIN_ARBITRUM_SEPOLIA), uint256(SEL_ARBITRUM_SEPOLIA));
    }

    function test_fromNativeChainId_mapsSupportedTestnets() public view {
        assertEq(adapter.fromNativeChainId(uint256(SEL_SEPOLIA)), CHAIN_SEPOLIA);
        assertEq(adapter.fromNativeChainId(uint256(SEL_BASE_SEPOLIA)), CHAIN_BASE_SEPOLIA);
        assertEq(adapter.fromNativeChainId(uint256(SEL_ARBITRUM_SEPOLIA)), CHAIN_ARBITRUM_SEPOLIA);
    }

    function test_testnetsRoundTrip() public view {
        uint256[3] memory chains = [CHAIN_SEPOLIA, CHAIN_BASE_SEPOLIA, CHAIN_ARBITRUM_SEPOLIA];
        for (uint256 i = 0; i < chains.length; i++) {
            assertEq(adapter.fromNativeChainId(adapter.toNativeChainId(chains[i])), chains[i]);
        }
    }

    /// @dev A mainnet chain id must never resolve to a testnet selector, or a
    ///      lane silently points at the wrong network.
    function test_testnetAndMainnetSelectorsAreDisjoint() public view {
        assertTrue(adapter.toNativeChainId(CHAIN_ETH_MAINNET) != uint256(SEL_SEPOLIA), "eth vs sepolia");
        assertTrue(adapter.toNativeChainId(CHAIN_BASE) != uint256(SEL_BASE_SEPOLIA), "base vs base-sepolia");
        assertTrue(
            adapter.toNativeChainId(CHAIN_ARBITRUM_ONE) != uint256(SEL_ARBITRUM_SEPOLIA), "arbitrum vs arb-sepolia"
        );
    }
}
