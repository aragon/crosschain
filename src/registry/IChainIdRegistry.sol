// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

/// @title IChainIdRegistry
/// @notice The chain id translation table an adapter resolves its lanes through.
/// @dev One registry per adapter protocol: CCIP addresses chains by its own
///      selector, another bridge by something else, and the two tables are
///      unrelated. The adapter binds its registry at construction.
///
///      Both directions return `0` for an unmapped id rather than reverting.
///      `IBaseAdapter` requires the ADAPTER's mappers to revert instead, so
///      `BaseAdapter` is where `0` is turned into a revert - see
///      {BaseAdapter-toNativeChainId}.
/// @custom:security-contact sirt@aragon.org
interface IChainIdRegistry {
    /// @notice Emitted when a chain id pair is set, repointed or cleared.
    /// @param standardChainId The standard (EVM) chain id.
    /// @param nativeChainId The bridge's own id for that chain; `0` when the
    ///        lane is cleared.
    event ChainIdPairSet(uint256 indexed standardChainId, uint256 nativeChainId);

    /// @notice Translates a standard chain id into its bridge-native counterpart.
    /// @param _standardChainId The standard (EVM) chain id.
    /// @return The bridge-native chain id, or `0` when unmapped.
    function toNative(uint256 _standardChainId) external view returns (uint256);

    /// @notice Translates a bridge-native chain id into its standard counterpart.
    /// @param _nativeChainId The bridge's own id for a chain.
    /// @return The standard (EVM) chain id, or `0` when unmapped.
    function fromNative(uint256 _nativeChainId) external view returns (uint256);
}
