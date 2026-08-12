// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/// @title ChainIds
/// @notice Standard (EVM) chain ids used by the cross-chain adapters.
/// @custom:security-contact sirt@aragon.org
library ChainIds {
    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant CRONOS = 25;
    uint256 internal constant BNB = 56;
    uint256 internal constant POLYGON = 137;
    uint256 internal constant MONAD = 143;
    uint256 internal constant HYPER_EVM = 999;
    uint256 internal constant MEGA_ETH = 4326;
    uint256 internal constant BASE = 8453;
    uint256 internal constant PLASMA = 9745;
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant AVALANCHE = 43114;
    uint256 internal constant INK = 57073;
    uint256 internal constant LINEA = 59144;
    uint256 internal constant KATANA = 747474;

    // Testnets. Supported so a deployment can be rehearsed against the same
    // adapter it will run on in production. Without them `CCIPAdapter` reverts
    // `UNKNOWN_CHAIN_ID` on every testnet lane, which forces a consumer to
    // subclass the adapter and override the table -- and then the rehearsal
    // proves a different contract than the one that ships.
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
}
