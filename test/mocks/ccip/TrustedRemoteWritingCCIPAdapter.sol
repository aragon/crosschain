// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";

/// @notice A `CCIPAdapter` whose send path also updates `_trustedRemotes` --
///         the adapter's ONLY declared storage. Honest bookkeeping in
///         isolation, but under the controller's `delegatecall` the write
///         resolves against the CONTROLLER's storage instead of the adapter's
///         own. Demonstrates the accidental-corruption hazard the
///         immutables-only rule exists for.
/// @dev DO NOT USE IN PRODUCTION!
contract TrustedRemoteWritingCCIPAdapter is CCIPAdapter {
    constructor(address _controller, address _router)
        CCIPAdapter(_controller, _router, address(0), new BaseAdapter.TrustedRemoteConfig[](0))
    { }

    function sendMessage(address _receiver, uint256 _destinationChainId, uint256 _gasLimit, bytes calldata _message)
        public
        payable
        override
        returns (uint256, uint256)
    {
        _trustedRemotes[_destinationChainId] = _receiver;
        return super.sendMessage(_receiver, _destinationChainId, _gasLimit, _message);
    }
}
