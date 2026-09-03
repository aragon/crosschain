// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

/// @title IChainIdRegistry
/// @notice The chain id translation table an adapter resolves its lanes through.
/// @dev One registry per bridge protocol. Both directions answer `0` for an
///      unmapped id; `BaseAdapter` turns that into a revert.
/// @custom:security-contact sirt@aragon.org
interface IChainIdRegistry {
    /// @notice Emitted when a chain id pair is set, repointed or cleared.
    /// @param nativeChainId The bridge's own id, or `0` when the lane is cleared.
    event ChainIdPairSet(uint256 indexed standardChainId, uint256 nativeChainId);

    /// @notice The bridge-native id for a standard chain id, or `0` if unmapped.
    function toNative(uint256 _standardChainId) external view returns (uint256);

    /// @notice The standard chain id for a bridge-native id, or `0` if unmapped.
    function fromNative(uint256 _nativeChainId) external view returns (uint256);
}
