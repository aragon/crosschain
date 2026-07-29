// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";

/// @notice A `CCIPAdapter` whose chain-id map returns a value one wider than
///         `uint64`, to exercise the `SafeCast.toUint64` guard on the send
///         path. The built-in map only ever returns `uint64`-sized CCIP
///         selectors, so the guard can only trip via a subclass like this one.
/// @dev DO NOT USE IN PRODUCTION!
contract OversizedSelectorCCIPAdapter is CCIPAdapter {
    constructor(address _controller, address _router)
        CCIPAdapter(_controller, _router, address(0), new BaseAdapter.TrustedRemoteConfig[](0))
    { }

    function toNativeChainId(uint256) public pure override returns (uint256) {
        return uint256(type(uint64).max) + 1;
    }
}
