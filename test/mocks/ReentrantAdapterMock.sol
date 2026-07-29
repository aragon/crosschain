// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { ICrossChainController } from "@src/ICrossChainController.sol";

/// @notice A registered "adapter" that doubles as an action target: while the
///         controller is executing a message's actions, `reenter` re-delivers
///         the SAME envelope, probing the dedup/reentrancy guard
///         (`record.state` is set BEFORE `executeActions` runs).
///         The reentrant call's outcome is recorded, not bubbled, so the outer
///         delivery proceeds and the test can inspect both results.
/// @dev DO NOT USE IN PRODUCTION! Test-only. This mock is only ever CALLed
///      (receive path), so keeping state here is safe.
contract ReentrantAdapterMock {
    address public immutable CONTROLLER;

    bytes public envelope;
    uint256 public chainId;

    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor(address _controller) {
        CONTROLLER = _controller;
    }

    /// @notice Stores the envelope `reenter` will try to re-deliver.
    function prime(bytes calldata _envelope, uint256 _chainId) external {
        envelope = _envelope;
        chainId = _chainId;
    }

    /// @notice The action executed mid-delivery: re-delivers the primed
    ///         envelope from this (registered) adapter.
    function reenter() external {
        try ICrossChainController(CONTROLLER).receiveMessage(0, envelope, chainId) returns (bytes32) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryRevertData = reason;
        }
    }
}
