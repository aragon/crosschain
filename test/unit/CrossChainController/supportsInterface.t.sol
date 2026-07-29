// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { ICrossChainController } from "@src/ICrossChainController.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract CrossChainControllerSupportsInterfaceTest is CrossChainControllerBase {
    function test_supportsOwnInterfaceAndErc165() public view {
        assertTrue(controller.supportsInterface(type(ICrossChainController).interfaceId));
        assertTrue(controller.supportsInterface(type(IERC165).interfaceId));
    }

    function test_rejectsUnknownInterfaceIds() public view {
        // `0xffffffff` is the id ERC-165 REQUIRES to be reported unsupported.
        assertFalse(controller.supportsInterface(0xffffffff));
        assertFalse(controller.supportsInterface(0xdeadbeef));
    }
}
