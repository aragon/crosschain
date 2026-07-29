// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice Minimal target with observable, readable state, used to prove an
///         action actually executed (and how many times) rather than inferring
///         success from the absence of a revert.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract CounterTarget {
    uint256 public count;

    function increment() external {
        count += 1;
    }
}
