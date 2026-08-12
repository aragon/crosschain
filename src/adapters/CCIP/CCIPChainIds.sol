// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/// @title CCIPChainIds
/// @notice CCIP addresses chains by its own selector rather
///         than by the EVM chain id.
/// @custom:security-contact sirt@aragon.org
library CCIPChainIds {
    uint64 internal constant ETHEREUM = 5009297550715157269;
    uint64 internal constant OPTIMISM = 3734403246176062136;
    uint64 internal constant CRONOS = 1456215246176062136;
    uint64 internal constant BNB = 11344663589394136015;
    uint64 internal constant POLYGON = 4051577828743386545;
    uint64 internal constant MONAD = 8481857512324358265;
    uint64 internal constant HYPER_EVM = 2442541497099098535;
    uint64 internal constant MEGA_ETH = 6093540873831549674;
    uint64 internal constant BASE = 15971525489660198786;
    uint64 internal constant PLASMA = 9335212494177455608;
    uint64 internal constant ARBITRUM_ONE = 4949039107694359620;
    uint64 internal constant AVALANCHE = 6433500567565415381;
    uint64 internal constant INK = 3461204551265785888;
    uint64 internal constant LINEA = 4627098889531055414;
    uint64 internal constant KATANA = 2459028469735686113;
}
