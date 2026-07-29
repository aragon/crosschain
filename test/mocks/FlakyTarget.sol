// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice Minimal target whose revert behaviour can be flipped on demand,
///         used to prove `retryMessage` succeeds once the underlying failure
///         condition is actually fixed (as opposed to merely being re-run).
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract FlakyTarget {
    bool public shouldRevert = true;
    bool public wasCalled;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function maybeRevert() external {
        if (shouldRevert) revert("FlakyTarget: still failing");
        wasCalled = true;
    }
}
