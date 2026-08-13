// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { DAO } from "@aragon/osx/core/dao/DAO.sol";

import { CrossChainController } from "../../src/CrossChainController.sol";
import { Executor } from "../../src/Executor.sol";
import { Permissions } from "../../src/lib/Permissions.sol";

/// @notice One chain's produced addresses.
/// @dev Deliberately narrow, rather than the kit's `ChainCfg`. `ChainCfg`
///      carries every config input too, and returning it across an ABI boundary
///      generates an encoder heavy enough to blow the stack in a consumer that
///      compiles without `via_ir` — which is what happened the first time a
///      consumer inherited this suite. Assertions only ever need the outputs.
///
///      File-level so a consumer's harness can build one without inheriting the
///      assertions.
struct Deployed {
    address dao;
    address controller;
    address executor;
    address adapter;
    address[] governors;
}

/// @title CrossChainDeployConformance
/// @notice The properties a finished deployment must have, as assertions a
///         consumer can point at its own run.
/// @dev **Why this lives here and not in a document.** Two projects that deploy
///      the same stack will drift, and a convention written down in each of
///      their repos drifts with them. These are one copy, versioned with the
///      contracts, and a consumer that stops satisfying one gets a failing test
///      rather than a stale paragraph.
///
///      Each assertion names the failure it prevents, because several of them
///      are invisible on chain until something silently does not happen — a
///      veto that never arrives, a DAO nobody notices is frozen until they need
///      to repair it.
///
///      Usage: inherit, and call `assertConformant` with each chain's config
///      while standing on that chain's fork.
abstract contract CrossChainDeployConformance is Test {
    /// @notice Every property, for one chain. Call while that chain is selected.
    function assertConformant(Deployed memory _c, address _psp, address _deployer) internal view {
        assertArtefactsExist(_c);
        assertNoEoaCanExecute(_c, _deployer);
        assertGovernorsCanExecute(_c);
        assertControllerHoldsNothingOnItsDao(_c);
        assertDedicatedExecutor(_c);
        assertPspReturnedRoot(_c, _psp);
        assertDaoCanConfigureItsController(_c);
    }

    /// @dev Each artefact must have code ON THIS CHAIN. Addresses can coincide
    ///      across chains — same factory nonce — so holding a non-zero address
    ///      proves nothing about where the thing actually is.
    function assertArtefactsExist(Deployed memory _c) internal view {
        assertGt(_c.dao.code.length, 0, "conformance: dao has no code on this chain");
        assertGt(_c.controller.code.length, 0, "conformance: controller has no code on this chain");
        assertGt(_c.executor.code.length, 0, "conformance: executor has no code on this chain");
        assertGt(_c.adapter.code.length, 0, "conformance: adapter has no code on this chain");
    }

    /// @dev Prevents: the deploying key keeping permanent unconditional
    ///      authority over a live DAO, bypassing its governance entirely.
    function assertNoEoaCanExecute(Deployed memory _c, address _deployer) internal view {
        DAO dao = DAO(payable(_c.dao));
        assertFalse(
            dao.hasPermission(_c.dao, _deployer, dao.EXECUTE_PERMISSION_ID(), ""),
            "conformance: the deployer can still act as this DAO"
        );
    }

    /// @dev Prevents: a DAO nothing can act as. The controller grants
    ///      MANAGE_CONTROLLER_CONFIG, CANCEL_MESSAGE, SWEEP, PAUSE, UNPAUSE and
    ///      UPGRADE_PLUGIN to the DAO and to nobody else, so a frozen DAO means
    ///      a wrong lane, a stranded message and an upstream security fix are
    ///      all permanently out of reach.
    function assertGovernorsCanExecute(Deployed memory _c) internal view {
        DAO dao = DAO(payable(_c.dao));
        assertGt(_c.governors.length, 0, "conformance: no governor declared for this DAO");
        for (uint256 i = 0; i < _c.governors.length; i++) {
            assertTrue(
                dao.hasPermission(_c.dao, _c.governors[i], dao.EXECUTE_PERMISSION_ID(), ""),
                "conformance: a declared governor cannot execute as the DAO"
            );
        }
    }

    /// @dev Prevents: an inbound cross-chain message executing with full DAO
    ///      authority. If the controller holds EXECUTE on its DAO, anything that
    ///      clears the adapter can do anything the DAO can.
    function assertControllerHoldsNothingOnItsDao(Deployed memory _c) internal view {
        DAO dao = DAO(payable(_c.dao));
        assertFalse(
            dao.hasPermission(_c.dao, _c.controller, dao.EXECUTE_PERMISSION_ID(), ""),
            "conformance: the controller can act as its own DAO"
        );
    }

    /// @dev The flip side: inbound payloads must still have somewhere to run, and
    ///      that somewhere is a helper owned by the controller — so remote roles
    ///      are granted to the executor, never to the DAO or the controller.
    function assertDedicatedExecutor(Deployed memory _c) internal view {
        assertTrue(_c.executor != _c.dao, "conformance: the executor is the DAO");
        assertTrue(_c.executor != _c.controller, "conformance: the executor is the controller");
        assertEq(
            Executor(payable(_c.executor)).owner(),
            _c.controller,
            "conformance: the executor is not owned by its controller"
        );
    }

    /// @dev Prevents: the PSP keeping ROOT on a DAO after an installation. It
    ///      needs ROOT for exactly one transaction; anything longer is a second
    ///      unconditional authority over the DAO.
    function assertPspReturnedRoot(Deployed memory _c, address _psp) internal view {
        DAO dao = DAO(payable(_c.dao));
        assertFalse(
            dao.hasPermission(_c.dao, _psp, dao.ROOT_PERMISSION_ID(), ""), "conformance: the PSP still holds ROOT"
        );
    }

    /// @dev Proves the installation was applied rather than merely prepared.
    function assertDaoCanConfigureItsController(Deployed memory _c) internal view {
        assertTrue(
            DAO(payable(_c.dao))
                .hasPermission(_c.controller, _c.dao, Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID, ""),
            "conformance: the installation was never applied"
        );
    }

    /// @notice A lane, from the perspective of the chain currently selected.
    /// @dev Prevents the mistake that is invisible until a message silently
    ///      fails to arrive: local and remote adapters transposed.
    function assertLaneWired(address _controller, uint256 _remoteChainId, address _localAdapter, address _remoteAdapter)
        internal
        view
    {
        (address local, address remote) = CrossChainController(payable(_controller)).chainToAdapter(_remoteChainId);
        assertEq(local, _localAdapter, "conformance: lane's local adapter is not this chain's");
        assertEq(remote, _remoteAdapter, "conformance: lane's remote adapter is not the counterpart's");
    }
}
