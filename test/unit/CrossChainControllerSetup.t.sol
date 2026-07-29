// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { CrossChainController } from "@src/CrossChainController.sol";
import { CrossChainControllerSetup } from "@src/CrossChainControllerSetup.sol";
import { Executor } from "@src/Executor.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { PermissionLib } from "@aragon/osx-commons-contracts/src/permission/PermissionLib.sol";
import { IPluginSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import { PluginUpgradeableSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/PluginUpgradeableSetup.sol";
import { CrossChainControllerDAOMock } from "@mocks/CrossChainControllerDAOMock.sol";

/// @title CrossChainControllerSetupTest
/// @notice Tests the OSx plugin setup: proxy deployment, executor wiring, and
///         -- most importantly -- the exact permission arrays. The permission
///         count arithmetic in `_getPermissions` (8 base, +1 guardian, +1
///         executor-is-DAO) is hand-maintained against hand-written array
///         indices, so these tests pin every entry.
contract CrossChainControllerSetupTest is Test {
    CrossChainController internal implementation;
    CrossChainControllerSetup internal setup;
    CrossChainControllerDAOMock internal daoMock;

    address internal guardian;

    function setUp() public {
        implementation = new CrossChainController();
        setup = new CrossChainControllerSetup(address(implementation));
        daoMock = new CrossChainControllerDAOMock();

        guardian = makeAddr("guardian");
    }

    /// @dev The 8 plugin-scoped permissions, in the exact order
    ///      `_getPermissions` writes them.
    function _basePermissionIds() internal pure returns (bytes32[8] memory) {
        return [
            Permissions.FORWARD_MESSAGE_PERMISSION_ID,
            Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID,
            Permissions.RETRY_MESSAGE_PERMISSION_ID,
            Permissions.CANCEL_MESSAGE_PERMISSION_ID,
            Permissions.SWEEP_PERMISSION_ID,
            Permissions.PAUSE_PERMISSION_ID,
            Permissions.UNPAUSE_PERMISSION_ID,
            Permissions.UPGRADE_PLUGIN_PERMISSION_ID
        ];
    }

    function _assertPermission(
        PermissionLib.MultiTargetPermission memory _permission,
        PermissionLib.Operation _op,
        address _where,
        address _who,
        bytes32 _id,
        string memory _label
    )
        internal
        pure
    {
        assertEq(uint256(_permission.operation), uint256(_op), string.concat(_label, ": operation"));
        assertEq(_permission.where, _where, string.concat(_label, ": where"));
        assertEq(_permission.who, _who, string.concat(_label, ": who"));
        assertEq(_permission.condition, PermissionLib.NO_CONDITION, string.concat(_label, ": condition"));
        assertEq(_permission.permissionId, _id, string.concat(_label, ": permissionId"));
    }

    /// @dev Asserts entries [0..7]: Grant/Revoke on the PLUGIN for the DAO, in
    ///      the canonical order.
    function _assertBasePermissions(
        PermissionLib.MultiTargetPermission[] memory _permissions,
        PermissionLib.Operation _op,
        address _plugin
    )
        internal
        view
    {
        bytes32[8] memory ids = _basePermissionIds();
        for (uint256 i = 0; i < ids.length; i++) {
            _assertPermission(_permissions[i], _op, _plugin, address(daoMock), ids[i], vm.toString(i));
        }
    }

    // -------------------------------------------------------------------------
    // Installation parameter codec.
    // -------------------------------------------------------------------------

    function test_installationParametersRoundTrip() public {
        address executor = makeAddr("executor");
        uint256 minFailedMessageGas = 12_345;

        (address decodedExecutor, address decodedGuardian, uint256 decodedMinFailedMessageGas) = setup.decodeInstallationParameters(
            setup.encodeInstallationParameters(executor, guardian, minFailedMessageGas)
        );

        assertEq(decodedExecutor, executor);
        assertEq(decodedGuardian, guardian);
        assertEq(decodedMinFailedMessageGas, minFailedMessageGas);
    }

    /// @dev The reserve is an installation parameter, so it must reach the
    ///      deployed plugin rather than being defaulted somewhere in between.
    function test_installationPassesMinFailedMessageGasToThePlugin() public {
        uint256 minFailedMessageGas = 61_234;

        (address plugin,) = setup.prepareInstallation(
            address(daoMock), setup.encodeInstallationParameters(address(0), address(0), minFailedMessageGas)
        );

        assertEq(CrossChainController(payable(plugin)).minFailedMessageGas(), minFailedMessageGas);
    }

    // -------------------------------------------------------------------------
    // prepareInstallation.
    // -------------------------------------------------------------------------

    function test_installsProxyWiredToDaoAndProvidedExecutor() public {
        Executor providedExecutor = new Executor();

        (address plugin, IPluginSetup.PreparedSetupData memory data) = setup.prepareInstallation(
            address(daoMock), setup.encodeInstallationParameters(address(providedExecutor), address(0), 45_000)
        );

        assertTrue(plugin.code.length > 0);
        assertEq(setup.implementation(), address(implementation));
        assertEq(address(CrossChainController(payable(plugin)).dao()), address(daoMock));
        assertEq(CrossChainController(payable(plugin)).executor(), address(providedExecutor));

        assertEq(data.helpers.length, 1);
        assertEq(data.helpers[0], address(providedExecutor));
        // A provided executor's ownership is NOT touched.
        assertEq(providedExecutor.owner(), address(this));

        assertEq(data.permissions.length, 8, "no guardian, executor != dao: exactly the 8 base permissions");
        _assertBasePermissions(data.permissions, PermissionLib.Operation.Grant, plugin);
    }

    function test_deploysOwnerGatedExecutorWhenNoneProvided() public {
        (address plugin, IPluginSetup.PreparedSetupData memory data) = setup.prepareInstallation(
            address(daoMock), setup.encodeInstallationParameters(address(0), address(0), 45_000)
        );

        address deployedExecutor = data.helpers[0];
        assertTrue(deployedExecutor != address(0));
        assertTrue(deployedExecutor.code.length > 0);

        // The fresh executor answers ONLY to the plugin.
        assertEq(Executor(payable(deployedExecutor)).owner(), plugin);
        assertEq(CrossChainController(payable(plugin)).executor(), deployedExecutor);
    }

    /// @dev The guardian gets PAUSE and NOTHING else -- reopening the paths
    ///      stays with the DAO.
    function test_guardianGetsPauseOnlyNeverUnpause() public {
        Executor providedExecutor = new Executor();

        (address plugin, IPluginSetup.PreparedSetupData memory data) = setup.prepareInstallation(
            address(daoMock), setup.encodeInstallationParameters(address(providedExecutor), guardian, 45_000)
        );

        assertEq(data.permissions.length, 9);
        _assertBasePermissions(data.permissions, PermissionLib.Operation.Grant, plugin);
        _assertPermission(
            data.permissions[8],
            PermissionLib.Operation.Grant,
            plugin,
            guardian,
            Permissions.PAUSE_PERMISSION_ID,
            "guardian"
        );

        // No entry beyond [8] exists, and no other entry names the guardian --
        // in particular UNPAUSE must never be granted to it.
        for (uint256 i = 0; i < 8; i++) {
            assertTrue(data.permissions[i].who != guardian, "guardian must hold nothing but PAUSE");
        }
    }

    /// @dev When the DAO itself is the executor, the plugin needs EXECUTE on
    ///      the DAO -- the one entry whose `where`/`who` are inverted.
    function test_daoAsExecutorGrantsPluginExecuteOnTheDao() public {
        (address plugin, IPluginSetup.PreparedSetupData memory data) = setup.prepareInstallation(
            address(daoMock), setup.encodeInstallationParameters(address(daoMock), address(0), 45_000)
        );

        assertEq(CrossChainController(payable(plugin)).executor(), address(daoMock));

        assertEq(data.permissions.length, 9);
        _assertBasePermissions(data.permissions, PermissionLib.Operation.Grant, plugin);
        _assertPermission(
            data.permissions[8],
            PermissionLib.Operation.Grant,
            address(daoMock),
            plugin,
            Permissions.EXECUTE_PERMISSION_ID,
            "execute-on-dao"
        );
    }

    function test_guardianAndDaoExecutorYieldTenPermissions() public {
        (address plugin, IPluginSetup.PreparedSetupData memory data) = setup.prepareInstallation(
            address(daoMock), setup.encodeInstallationParameters(address(daoMock), guardian, 45_000)
        );

        assertEq(data.permissions.length, 10);
        _assertBasePermissions(data.permissions, PermissionLib.Operation.Grant, plugin);
        _assertPermission(
            data.permissions[8],
            PermissionLib.Operation.Grant,
            plugin,
            guardian,
            Permissions.PAUSE_PERMISSION_ID,
            "guardian"
        );
        _assertPermission(
            data.permissions[9],
            PermissionLib.Operation.Grant,
            address(daoMock),
            plugin,
            Permissions.EXECUTE_PERMISSION_ID,
            "execute-on-dao"
        );
    }

    // -------------------------------------------------------------------------
    // prepareUpdate / prepareUninstallation.
    // -------------------------------------------------------------------------

    /// @dev Build 1 is the initial build: EVERY update path into it reverts.
    function test_prepareUpdateAlwaysReverts() public {
        IPluginSetup.SetupPayload memory payload =
            IPluginSetup.SetupPayload({ plugin: makeAddr("plugin"), currentHelpers: new address[](0), data: "" });

        vm.expectRevert(abi.encodeWithSelector(PluginUpgradeableSetup.InvalidUpdatePath.selector, 3, 1));
        setup.prepareUpdate(address(daoMock), 3, payload);
    }

    /// @dev Uninstall revokes the 8 base permissions AND always the
    ///      execute-on-DAO grant (whether or not it was ever given -- revoking
    ///      an ungranted permission is a no-op). The guardian's PAUSE cannot be
    ///      determined here and deliberately stays.
    function test_uninstallRevokesBasePermissionsAndDaoExecute() public {
        address plugin = makeAddr("plugin");
        IPluginSetup.SetupPayload memory payload =
            IPluginSetup.SetupPayload({ plugin: plugin, currentHelpers: new address[](0), data: "" });

        PermissionLib.MultiTargetPermission[] memory permissions =
            setup.prepareUninstallation(address(daoMock), payload);

        assertEq(permissions.length, 9);
        _assertBasePermissions(permissions, PermissionLib.Operation.Revoke, plugin);
        _assertPermission(
            permissions[8],
            PermissionLib.Operation.Revoke,
            address(daoMock),
            plugin,
            Permissions.EXECUTE_PERMISSION_ID,
            "execute-on-dao"
        );
    }
}
