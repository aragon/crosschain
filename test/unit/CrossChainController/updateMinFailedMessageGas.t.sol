// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";

contract CrossChainControllerUpdateMinFailedMessageGasTest is CrossChainControllerBase {
    // -------------------------------------------------------------------------
    // Initialization.
    // -------------------------------------------------------------------------

    /// @dev The reserve reaches storage through `initialize`, not a later
    ///      config call, so a fresh proxy must already carry it.
    function test_initializeStoresTheReserveAndEmitsFromZero() public {
        vm.expectEmit(true, true, true, true);
        emit MinFailedMessageGasUpdated(0, MIN_FAILED_MESSAGE_GAS);

        CrossChainController fresh = deployController(address(daoMock), address(daoMock));

        assertEq(fresh.minFailedMessageGas(), MIN_FAILED_MESSAGE_GAS);
    }

    // -------------------------------------------------------------------------
    // Auth.
    // -------------------------------------------------------------------------

    function test_revertsIfCallerUnauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector, address(daoMock), address(controller), bob, manageConfigPermissionId
            )
        );
        vm.prank(bob);
        controller.updateMinFailedMessageGas(1);
    }

    // -------------------------------------------------------------------------
    // Happy path.
    // -------------------------------------------------------------------------

    function test_setsReserveAndEmitsTheReplacedValue() public {
        uint256 newReserve = MIN_FAILED_MESSAGE_GAS + 10_000;

        vm.expectEmit(true, true, true, true, address(controller));
        emit MinFailedMessageGasUpdated(MIN_FAILED_MESSAGE_GAS, newReserve);

        vm.prank(alice);
        controller.updateMinFailedMessageGas(newReserve);

        assertEq(controller.minFailedMessageGas(), newReserve);
    }

    /// @dev `0` is explicitly valid -- it disables the reserve rather than
    ///      being rejected as an unset value.
    function test_allowsZeroToDisableTheReserve() public {
        vm.expectEmit(true, true, true, true, address(controller));
        emit MinFailedMessageGasUpdated(MIN_FAILED_MESSAGE_GAS, 0);

        vm.prank(alice);
        controller.updateMinFailedMessageGas(0);

        assertEq(controller.minFailedMessageGas(), 0);
    }
}
