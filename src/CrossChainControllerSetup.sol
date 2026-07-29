// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { PermissionLib } from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import { PluginUpgradeableSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/PluginUpgradeableSetup.sol";
import { IPluginSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import { ProxyLib } from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import { CrossChainController } from "./CrossChainController.sol";
import { Executor } from "./Executor.sol";
import { Permissions } from "./lib/Permissions.sol";

/// @title CrossChainControllerSetup
/// @notice The setup contract installing, updating and uninstalling
///         `CrossChainController` as an Aragon OSx plugin.
/// @custom:security-contact sirt@aragon.org
contract CrossChainControllerSetup is PluginUpgradeableSetup {
    using ProxyLib for address;

    /// @notice The build number this setup deploys. Build 1 is the initial
    ///         build, so there is no update path INTO it.
    uint16 internal constant THIS_BUILD = 1;

    /// @notice Sets the implementation the proxies point at.
    /// @param _implementation An existing `CrossChainController` implementation
    constructor(address _implementation) PluginUpgradeableSetup(_implementation) { }

    /// @inheritdoc IPluginSetup
    function prepareInstallation(address _dao, bytes calldata _data)
        external
        override
        returns (address plugin, PreparedSetupData memory preparedSetupData)
    {
        (address executor, address guardian, uint256 minFailedMessageGas) = decodeInstallationParameters(_data);

        // No executor requested: deploy a dedicated, owner-gated one.
        // ownership is handed to the crosschain controller plugin.
        bool deployedExecutor = executor == address(0);
        if (deployedExecutor) executor = address(new Executor());

        plugin = IMPLEMENTATION.deployUUPSProxy(
            abi.encodeCall(CrossChainController.initialize, (IDAO(_dao), executor, minFailedMessageGas))
        );

        // Only the plugin may execute inbound payloads on this executor.
        if (deployedExecutor) Executor(payable(executor)).transferOwnership(plugin);

        preparedSetupData.permissions =
            _getPermissions(_dao, plugin, guardian, executor == _dao, PermissionLib.Operation.Grant);

        preparedSetupData.helpers = new address[](1);
        preparedSetupData.helpers[0] = executor;
    }

    /// @inheritdoc IPluginSetup
    /// @dev This is build 1, the initial build, so no update path leads here.
    function prepareUpdate(address _dao, uint16 _fromBuild, SetupPayload calldata _payload)
        external
        pure
        override
        returns (bytes memory, PreparedSetupData memory)
    {
        (_dao, _payload);
        revert InvalidUpdatePath({ fromBuild: _fromBuild, thisBuild: THIS_BUILD });
    }

    /// @inheritdoc IPluginSetup
    function prepareUninstallation(address _dao, SetupPayload calldata _payload)
        external
        pure
        override
        returns (PermissionLib.MultiTargetPermission[] memory permissions)
    {
        // Guardian can not be determined if it was given a permission in prepareInstallation.
        // Below permission revoke are enough even if guardian stays with pause permission.

        // There's a chance executor might have been set as DAO
        // and permission not removed after it was set to another executor.
        // Pass `true` so it always tries to revoke EXECUTE_PERMISSION from
        // CrosschainController on the dao. Revoke doesn't revert if permission
        // is not currently granted.
        permissions = _getPermissions(_dao, _payload.plugin, address(0), true, PermissionLib.Operation.Revoke);
    }

    /// @notice Encodes the given installation parameters into a byte array
    /// @param minFailedMessageGas Gas the controller withholds so a failed
    ///        inbound message can always be recorded as `Delivered`. 45000 is a
    ///        good enough value; see `CrossChainController.initialize`.
    function encodeInstallationParameters(address executor, address guardian, uint256 minFailedMessageGas)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(executor, guardian, minFailedMessageGas);
    }

    /// @notice Decodes the given byte array into the original installation parameters.
    function decodeInstallationParameters(bytes memory _data)
        public
        pure
        returns (address executor, address guardian, uint256 minFailedMessageGas)
    {
        return abi.decode(_data, (address, address, uint256));
    }

    /// @notice Builds the plugin's full permission set for `_op`.
    function _getPermissions(
        address _dao,
        address _plugin,
        address _guardian,
        bool _executorIsDao,
        PermissionLib.Operation _op
    )
        internal
        pure
        returns (PermissionLib.MultiTargetPermission[] memory permissions)
    {
        bool hasGuardian = _guardian != address(0);

        uint256 count = 8;
        if (hasGuardian) count++;
        if (_executorIsDao) count++;

        permissions = new PermissionLib.MultiTargetPermission[](count);

        bytes32[8] memory pluginPermissionIds = [
            Permissions.FORWARD_MESSAGE_PERMISSION_ID,
            Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID,
            Permissions.RETRY_MESSAGE_PERMISSION_ID,
            Permissions.CANCEL_MESSAGE_PERMISSION_ID,
            Permissions.SWEEP_PERMISSION_ID,
            Permissions.PAUSE_PERMISSION_ID,
            Permissions.UNPAUSE_PERMISSION_ID,
            Permissions.UPGRADE_PLUGIN_PERMISSION_ID
        ];

        for (uint256 i = 0; i < pluginPermissionIds.length; i++) {
            permissions[i] = PermissionLib.MultiTargetPermission({
                operation: _op,
                where: _plugin,
                who: _dao,
                condition: PermissionLib.NO_CONDITION,
                permissionId: pluginPermissionIds[i]
            });
        }

        uint256 next = pluginPermissionIds.length;

        if (hasGuardian) {
            // Pause only, never unpause: a guardian is trusted to freeze the
            // message paths during an incident, but reopening them stays with
            // the DAO.
            permissions[next++] = PermissionLib.MultiTargetPermission({
                operation: _op,
                where: _plugin,
                who: _guardian,
                condition: PermissionLib.NO_CONDITION,
                permissionId: Permissions.PAUSE_PERMISSION_ID
            });
        }

        if (_executorIsDao) {
            // NOTE: `where` is the DAO, not the plugin -- this is the
            // controller acting ON the DAO, so inbound payloads can execute.
            permissions[next] = PermissionLib.MultiTargetPermission({
                operation: _op,
                where: _dao,
                who: _plugin,
                condition: PermissionLib.NO_CONDITION,
                permissionId: Permissions.EXECUTE_PERMISSION_ID
            });
        }
    }
}
