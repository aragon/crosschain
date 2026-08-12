// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { CCIPAdapter } from "../../src/adapters/CCIP/CCIPAdapter.sol";
import { Errors } from "../../src/lib/Errors.sol";

/// @title TestnetCCIPAdapter
/// @notice `CCIPAdapter` with the chain-id <-> CCIP-selector map REPLACED by the
///         testnets.
/// @dev TESTNET ONLY -- do not deploy to mainnet.
///
///      The production adapter maps mainnet chains exclusively, so
///      `toNativeChainId` would revert with `UNKNOWN_CHAIN_ID` on a testnet.
///      Both mapping functions are `virtual`, so the testnet lane is added by
///      subclassing rather than by touching production source.
///
///      Selectors are the official CCIP directory values, cross-checked against
///      `lib/chainlink-local/src/ccip/Register.sol`.
///
///      Sepolia was added because it is the hub in every testnet topology the
///      deploy kit rehearses, and this map REPLACES the production one rather
///      than extending it -- so a Sepolia lane was unreachable without it. The
///      original two chains came from a point-to-point retry experiment that
///      never needed a hub.
contract TestnetCCIPAdapter is CCIPAdapter {
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant ARBITRUM_SEPOLIA = 421_614;
    uint256 internal constant BASE_SEPOLIA = 84_532;

    uint64 internal constant SEPOLIA_SELECTOR = 16_015_286_601_757_825_753;
    uint64 internal constant ARBITRUM_SEPOLIA_SELECTOR = 3_478_487_238_524_512_106;
    uint64 internal constant BASE_SEPOLIA_SELECTOR = 10_344_971_235_874_465_080;

    constructor(
        address _crosschainController,
        address _ccipRouter,
        address _feeToken,
        TrustedRemoteConfig[] memory _trustedRemoteConfigs
    )
        CCIPAdapter(_crosschainController, _ccipRouter, _feeToken, _trustedRemoteConfigs)
    { }

    /// @inheritdoc CCIPAdapter
    function toNativeChainId(uint256 _chainId) public view virtual override returns (uint256) {
        if (_chainId == SEPOLIA) return SEPOLIA_SELECTOR;
        if (_chainId == ARBITRUM_SEPOLIA) return ARBITRUM_SEPOLIA_SELECTOR;
        if (_chainId == BASE_SEPOLIA) return BASE_SEPOLIA_SELECTOR;

        revert Errors.UNKNOWN_CHAIN_ID(_chainId);
    }

    /// @inheritdoc CCIPAdapter
    function fromNativeChainId(uint256 _chainId) public view virtual override returns (uint256) {
        if (_chainId == SEPOLIA_SELECTOR) return SEPOLIA;
        if (_chainId == ARBITRUM_SEPOLIA_SELECTOR) return ARBITRUM_SEPOLIA;
        if (_chainId == BASE_SEPOLIA_SELECTOR) return BASE_SEPOLIA;

        revert Errors.UNKNOWN_NATIVE_CHAIN_ID(_chainId);
    }
}
