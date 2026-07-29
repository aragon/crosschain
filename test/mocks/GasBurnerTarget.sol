// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice A target that consumes every unit of gas it is given, so the call
///         into it always ends in `OutOfGas` rather than a normal revert.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
///
///      Used to reach the state where `executeActions` runs out of gas while
///      `receiveMessage` still holds enough (the 63/64 reserve of a LARGE
///      budget) to record `Delivered` and emit. A plain reverting target cannot
///      produce that: it returns gas instead of burning it.
contract GasBurnerTarget {
    /// @notice Set once the burn loop has been entered, purely so the contract
    ///         has observable state; it is never actually persisted, because
    ///         the call always runs out of gas first.
    bool public entered;

    /// @notice Burns gas until the EVM halts this frame with `OutOfGas`.
    function burn() external {
        entered = true;

        // An unbounded loop doing real work; the compiler cannot elide it
        // because it writes to storage on every iteration.
        for (uint256 i = 0; true; i++) {
            assembly {
                sstore(add(i, 0x1000), i)
            }
        }
    }
}
