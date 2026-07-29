// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { Transaction, TransactionState, TransactionLib } from "@src/lib/Transaction.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";
import { ActionExecute } from "@osx-test/mocks/commons/executors/ActionExecute.sol";

contract CrossChainControllerUpgradeTest is CrossChainControllerBase {
    CrossChainController internal newImplementation;

    function setUp() public override {
        super.setUp();
        newImplementation = new CrossChainController();
    }

    function test_revertsForUpgraderWithoutPermission() public {
        // Even alice, who holds every OTHER permission, may not upgrade.
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(daoMock),
                address(controller),
                alice,
                Permissions.UPGRADE_PLUGIN_PERMISSION_ID
            )
        );
        vm.prank(alice);
        controller.upgradeTo(address(newImplementation));
    }

    function test_authorizedUpgradeSwapsImplementation() public {
        assertEq(controller.implementation(), address(controllerImplementation));

        daoMock.setHasPermission(address(controller), alice, Permissions.UPGRADE_PLUGIN_PERMISSION_ID, true);

        vm.prank(alice);
        controller.upgradeTo(address(newImplementation));

        assertEq(controller.implementation(), address(newImplementation));
    }

    function test_upgradePreservesLiveState() public {
        // 1. A configured lane and one consumed nonce.
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        vm.prank(alice);
        controller.forwardMessage(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());

        // 2. A delivered-but-failed (retryable) inbound record.
        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: address(actionTarget), value: 0, data: abi.encodeCall(ActionExecute.fail, ()) });
        bytes memory message = abi.encode(actions);
        bytes32 deliveredTxId = _txId(9, CHAIN_ID, message);
        vm.prank(address(adapterA));
        controller.receiveMessage(9, _encodedTx(9, CHAIN_ID, message), CHAIN_ID);

        // 3. A retry cutoff.
        vm.warp(1_000_000);
        vm.prank(alice);
        controller.updateRetryCutoff(OTHER_CHAIN_ID, uint120(999_999));

        // Upgrade.
        daoMock.setHasPermission(address(controller), alice, Permissions.UPGRADE_PLUGIN_PERMISSION_ID, true);
        vm.prank(alice);
        controller.upgradeTo(address(newImplementation));

        // Everything is still there.
        (address localAdapter, address remoteAdapter) = controller.chainToAdapter(CHAIN_ID);
        assertEq(localAdapter, address(adapterA), "lane config lost in upgrade");
        assertEq(remoteAdapter, remoteAdapterA);
        assertEq(controller.executor(), address(daoMock), "executor lost in upgrade");
        assertEq(controller.retryCutoff(OTHER_CHAIN_ID), uint120(999_999), "retry cutoff lost in upgrade");
        assertEq(
            uint256(controller.getTransaction(deliveredTxId).state),
            uint256(TransactionState.Delivered),
            "transaction record lost in upgrade"
        );

        // The nonce sequence continues at 2: the next forward's txId must be
        // the nonce-2 envelope's id, not a nonce-1 restart.
        bytes memory payload = _emptyActionsPayload();
        bytes32 expectedTxId = TransactionLib.id(
            Transaction({
                nonce: 2,
                origin: alice,
                controller: address(controller),
                originChainId: block.chainid,
                destinationChainId: CHAIN_ID,
                message: payload
            })
        );
        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(CHAIN_ID, GAS_LIMIT, payload);
        assertEq(txId, expectedTxId, "nonce sequence must continue across the upgrade");
    }
}
