// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice Returns the keccak of the envelope it was asked to quote as the
///         "fee", so tests can assert exactly which bytes the controller
///         quoted. Its `sendMessage` succeeds with zero fee so a quote/forward
///         pair can run against the same lane.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract QuoteEchoAdapterStub {
    function quoteFee(address, uint256, uint256, bytes calldata _message) external pure returns (address, uint256) {
        return (address(0), uint256(keccak256(_message)));
    }

    function sendMessage(address, uint256, uint256, bytes calldata) external payable returns (uint256, uint256) {
        return (1, 0);
    }
}
