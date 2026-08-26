// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { DaoAuthorizable } from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizable.sol";
import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import { Errors } from "../lib/Errors.sol";
import { Permissions } from "../lib/Permissions.sol";

import { IChainIdRegistry } from "./IChainIdRegistry.sol";

/// @title ChainIdRegistry
/// @notice A runtime-updatable chain id translation table for the adapters of a
///         single bridge protocol.
/// @dev Adding a chain to a live deployment is a governance call here instead
///      of an adapter redeploy + re-attach cycle on the controller.
///
///      SECURITY: this contract is a trust dependency of the adapter pointing
///      at it. Whoever holds `MANAGE_CHAIN_ID_REGISTRY_PERMISSION` can repoint
///      a live lane at a different bridge-native chain in a single call, which
///      would send messages to the wrong chain. It warrants the same
///      governance rigor as the controller itself.
/// @custom:security-contact sirt@aragon.org
contract ChainIdRegistry is IChainIdRegistry, DaoAuthorizable {
    /// @notice standard chain id -> bridge-native chain id.
    mapping(uint256 => uint256) private _toNative;

    /// @notice bridge-native chain id -> standard chain id.
    /// @dev Kept in lockstep with `_toNative`; the two are only ever written
    ///      together so they cannot drift.
    mapping(uint256 => uint256) private _fromNative;

    /// @param _dao The DAO whose permission manager authorizes updates.
    /// @dev `DaoAuthorizable` does not reject a zero DAO, and one built with it
    ///      is permanently unusable: every `auth` call reads `hasPermission` off
    ///      `address(0)`, which has no code. The adapter binds its registry as
    ///      an immutable, so that state is not repairable either.
    constructor(IDAO _dao) DaoAuthorizable(_dao) {
        if (address(_dao) == address(0)) revert Errors.ZERO_ADDRESS();
    }

    /// @inheritdoc IChainIdRegistry
    function toNative(uint256 _standardChainId) external view override returns (uint256) {
        return _toNative[_standardChainId];
    }

    /// @inheritdoc IChainIdRegistry
    function fromNative(uint256 _nativeChainId) external view override returns (uint256) {
        return _fromNative[_nativeChainId];
    }

    /// @notice Maps a standard chain id to its bridge-native counterpart, in
    ///         both directions.
    /// @param _standardChainId The standard (EVM) chain id.
    /// @param _nativeChainId The bridge's own id for that chain. Pass `0` to
    ///        clear the lane.
    /// @dev Clearing a lane makes every send to and receive from that chain
    ///      revert at the adapter. Inbound messages already in flight over the
    ///      bridge will fail on arrival.
    function setChainIdPair(uint256 _standardChainId, uint256 _nativeChainId)
        external
        auth(Permissions.MANAGE_CHAIN_ID_REGISTRY_PERMISSION_ID)
    {
        // `0` is the "unset" marker of both tables, so it is never a valid key.
        if (_standardChainId == 0) revert Errors.INVALID_CHAIN_ID();

        // Drop the previous reverse entry before writing the new one. Without
        // this a repoint would leave `_fromNative[old]` in place and the
        // receive path would keep accepting messages over the retired lane.
        uint256 previousNativeChainId = _toNative[_standardChainId];
        if (previousNativeChainId != 0) {
            delete _fromNative[previousNativeChainId];
        }

        _toNative[_standardChainId] = _nativeChainId;

        // `0` means "clear": the forward entry is now unset and there is no
        // reverse entry to write.
        if (_nativeChainId != 0) {
            _fromNative[_nativeChainId] = _standardChainId;
        }

        emit ChainIdPairSet(_standardChainId, _nativeChainId);
    }
}
