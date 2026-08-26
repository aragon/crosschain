// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import { DaoUnauthorized } from "@aragon/osx-commons-contracts/src/permission/auth/auth.sol";

import { ChainIdRegistry } from "@src/registry/ChainIdRegistry.sol";
import { IChainIdRegistry } from "@src/registry/IChainIdRegistry.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Permissions } from "@src/lib/Permissions.sol";

import { CrossChainControllerDAOMock } from "@mocks/CrossChainControllerDAOMock.sol";

/// @title ChainIdRegistryTest
/// @notice The chain id table adapters resolve their lanes through.
/// @dev Uses `CrossChainControllerDAOMock`: its `hasPermission` is per
///      `(where, who, permissionId)`, so "the manager may, nobody else may" is
///      expressible. The commons `DAOMock` is one global flag.
contract ChainIdRegistryTest is Test {
    CrossChainControllerDAOMock internal dao;
    ChainIdRegistry internal registry;

    address internal manager;
    address internal stranger;

    uint256 internal constant CHAIN = 1;
    uint256 internal constant SELECTOR = 5_009_297_550_715_157_269;
    uint256 internal constant OTHER_SELECTOR = 15_971_525_489_660_198_786;

    function setUp() public {
        manager = makeAddr("manager");
        stranger = makeAddr("stranger");

        dao = new CrossChainControllerDAOMock();
        registry = new ChainIdRegistry(IDAO(address(dao)));

        dao.setHasPermission(address(registry), manager, Permissions.MANAGE_CHAIN_ID_REGISTRY_PERMISSION_ID, true);
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    function test_storesTheDaoItWasGiven() public view {
        assertEq(address(registry.dao()), address(dao));
    }

    /// @dev `DaoAuthorizable` does not check this itself, and every `auth` call
    ///      would read `hasPermission` off an address with no code.
    function test_revertsIfTheDaoIsZeroAddress() public {
        vm.expectRevert(Errors.ZERO_ADDRESS.selector);
        new ChainIdRegistry(IDAO(address(0)));
    }

    // -------------------------------------------------------------------------
    // Reads before anything is written
    // -------------------------------------------------------------------------

    /// @dev `0` is the "unset" answer; `BaseAdapter` turns it into a revert.
    function test_bothDirectionsAnswerZeroBeforeAnyPairIsSet() public view {
        assertEq(registry.toNative(CHAIN), 0);
        assertEq(registry.fromNative(SELECTOR), 0);
    }

    // -------------------------------------------------------------------------
    // setChainIdPair
    // -------------------------------------------------------------------------

    function test_setsBothDirections() public {
        vm.prank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);

        assertEq(registry.toNative(CHAIN), SELECTOR);
        assertEq(registry.fromNative(SELECTOR), CHAIN);
    }

    function test_emitsChainIdPairSet() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IChainIdRegistry.ChainIdPairSet(CHAIN, SELECTOR);

        vm.prank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
    }

    function test_revertsForACallerWithoutThePermission() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DaoUnauthorized.selector,
                address(dao),
                address(registry),
                stranger,
                Permissions.MANAGE_CHAIN_ID_REGISTRY_PERMISSION_ID
            )
        );
        vm.prank(stranger);
        registry.setChainIdPair(CHAIN, SELECTOR);
    }

    /// @dev `0` is the unset marker of both tables, so it can never be a key.
    function test_revertsForAZeroStandardChainId() public {
        vm.expectRevert(Errors.INVALID_CHAIN_ID.selector);
        vm.prank(manager);
        registry.setChainIdPair(0, SELECTOR);
    }

    function test_aZeroNativeChainIdClearsTheLaneInBothDirections() public {
        vm.startPrank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
        registry.setChainIdPair(CHAIN, 0);
        vm.stopPrank();

        assertEq(registry.toNative(CHAIN), 0, "forward entry must be cleared");
        assertEq(registry.fromNative(SELECTOR), 0, "reverse entry must be cleared");
    }

    /// @dev What the `delete` in `setChainIdPair` exists for. Without it the
    ///      retired selector keeps resolving and the receive path goes on
    ///      accepting messages over a lane governance believes it retired.
    function test_repointingALaneDropsTheStaleReverseEntry() public {
        vm.startPrank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
        registry.setChainIdPair(CHAIN, OTHER_SELECTOR);
        vm.stopPrank();

        assertEq(registry.toNative(CHAIN), OTHER_SELECTOR, "forward entry must follow the repoint");
        assertEq(registry.fromNative(OTHER_SELECTOR), CHAIN, "new reverse entry must be written");
        assertEq(registry.fromNative(SELECTOR), 0, "the retired selector must stop resolving");
    }

    /// @dev The `delete` of the old reverse entry and the write of the new one
    ///      hit the same slot here, so their order decides the outcome.
    function test_repointingToTheSameSelectorIsANoOp() public {
        vm.startPrank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
        registry.setChainIdPair(CHAIN, SELECTOR);
        vm.stopPrank();

        assertEq(registry.toNative(CHAIN), SELECTOR);
        assertEq(registry.fromNative(SELECTOR), CHAIN);
    }

    /// @dev A misconfiguration the registry permits. Pinned so the asymmetry --
    ///      last writer owns the reverse entry, both forward entries survive --
    ///      is a known state rather than a surprise.
    function test_twoChainsPointedAtOneSelector_lastWriterOwnsTheReverseEntry() public {
        vm.startPrank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
        registry.setChainIdPair(CHAIN + 1, SELECTOR);
        vm.stopPrank();

        assertEq(registry.toNative(CHAIN), SELECTOR, "the first chain still maps forward");
        assertEq(registry.toNative(CHAIN + 1), SELECTOR, "so does the second");
        assertEq(registry.fromNative(SELECTOR), CHAIN + 1, "the reverse entry names the last writer");
    }

    function testFuzz_roundTripsAnyNonZeroPair(uint256 _chainId, uint256 _nativeChainId) public {
        vm.assume(_chainId != 0);
        vm.assume(_nativeChainId != 0);

        vm.prank(manager);
        registry.setChainIdPair(_chainId, _nativeChainId);

        assertEq(registry.toNative(_chainId), _nativeChainId);
        assertEq(registry.fromNative(_nativeChainId), _chainId);
    }

    function testFuzz_readsAreZeroForAnythingNeverWritten(uint256 _chainId) public {
        vm.assume(_chainId != CHAIN);

        vm.prank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);

        assertEq(registry.toNative(_chainId), 0);
    }
}
