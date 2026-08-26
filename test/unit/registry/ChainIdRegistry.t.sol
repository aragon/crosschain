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
/// @dev Uses `CrossChainControllerDAOMock` rather than the commons `DAOMock`:
///      its `hasPermission` is per `(where, who, permissionId)`, so "the manager
///      may write, nobody else may" is expressible. The commons mock is a single
///      global flag and would authorize every caller at once.
contract ChainIdRegistryTest is Test {
    CrossChainControllerDAOMock internal dao;
    ChainIdRegistry internal registry;

    address internal manager;
    address internal stranger;

    /// @dev Redeclared from `IChainIdRegistry` so `vm.expectEmit` can emit it.
    event ChainIdPairSet(uint256 indexed standardChainId, uint256 nativeChainId);

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

    /// @dev `DaoAuthorizable` does not check this itself, and the resulting
    ///      registry is unusable rather than merely misconfigured: every `auth`
    ///      call reads `hasPermission` off an address with no code. The adapter
    ///      binds its registry as an immutable, so there is no repair either.
    function test_revertsIfTheDaoIsZeroAddress() public {
        vm.expectRevert(Errors.ZERO_ADDRESS.selector);
        new ChainIdRegistry(IDAO(address(0)));
    }

    // -------------------------------------------------------------------------
    // Reads before anything is written
    // -------------------------------------------------------------------------

    /// @dev `0` is the "unset" answer in both directions. `BaseAdapter` is what
    ///      turns it into a revert -- see {BaseAdapter-toNativeChainId}.
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
        emit ChainIdPairSet(CHAIN, SELECTOR);

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
    ///      Accepting it would make an unmapped chain read as mapped.
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

    /// @dev The invariant the `delete` in `setChainIdPair` exists for. Without
    ///      it the retired selector keeps resolving to this chain, and the
    ///      RECEIVE path goes on accepting messages over a lane governance
    ///      believes it retired -- silently, because the send path looks right.
    function test_repointingALaneDropsTheStaleReverseEntry() public {
        vm.startPrank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
        registry.setChainIdPair(CHAIN, OTHER_SELECTOR);
        vm.stopPrank();

        assertEq(registry.toNative(CHAIN), OTHER_SELECTOR, "forward entry must follow the repoint");
        assertEq(registry.fromNative(OTHER_SELECTOR), CHAIN, "new reverse entry must be written");
        assertEq(registry.fromNative(SELECTOR), 0, "the retired selector must stop resolving");
    }

    /// @dev Repointing to the value already stored must not clear the pair: the
    ///      `delete` of the old reverse entry and the write of the new one are
    ///      the same slot, and the order they happen in decides the outcome.
    function test_repointingToTheSameSelectorIsANoOp() public {
        vm.startPrank(manager);
        registry.setChainIdPair(CHAIN, SELECTOR);
        registry.setChainIdPair(CHAIN, SELECTOR);
        vm.stopPrank();

        assertEq(registry.toNative(CHAIN), SELECTOR);
        assertEq(registry.fromNative(SELECTOR), CHAIN);
    }

    /// @dev Two chains sharing one selector is a misconfiguration, but the
    ///      registry must still not corrupt itself: the reverse entry belongs to
    ///      whoever wrote last, and the loser's forward entry survives. Pinned
    ///      so the asymmetry is a known state rather than a surprise.
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
