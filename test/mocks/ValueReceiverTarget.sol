// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice Payable target that records the `msg.value` it was called with, so a
///         test can prove how much native currency an action actually moved
///         instead of inferring it from balances alone.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract ValueReceiverTarget {
    uint256 public lastValue;
    uint256 public totalReceived;
    uint256 public calls;

    function pay() external payable {
        lastValue = msg.value;
        totalReceived += msg.value;
        calls += 1;
    }

    receive() external payable {
        lastValue = msg.value;
        totalReceived += msg.value;
        calls += 1;
    }
}
