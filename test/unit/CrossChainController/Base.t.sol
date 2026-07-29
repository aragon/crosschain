// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { CrossChainController } from "@src/CrossChainController.sol";
import { ICrossChainControllerEvents, ICrossChainController } from "@src/ICrossChainController.sol";
import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";
import { Permissions } from "@src/lib/Permissions.sol";
import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import { ProxyLib } from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { AdapterMock } from "@mocks/AdapterMock.sol";
import { CrossChainControllerDAOMock } from "@mocks/CrossChainControllerDAOMock.sol";
import { ERC20Mock } from "@mocks/ERC20Mock.sol";
import { ActionExecute } from "@osx-test/mocks/commons/executors/ActionExecute.sol";

/// @title CrossChainControllerBase
/// @notice Shared fixture for the per-function `CrossChainController` unit
///         tests: deploys the controller + mocks, wires alice with every
///         permission, and provides the envelope / storage-slot helpers each
///         function's test file builds on.
abstract contract CrossChainControllerBase is Test, ICrossChainControllerEvents {
    // Events come from `ICrossChainControllerEvents` (inherited), so
    // `vm.expectEmit` can `emit` them without a local redeclaration that could
    // drift from the contract's definitions.

    // -------------------------------------------------------------------------
    // Constants.
    // -------------------------------------------------------------------------
    //
    // Both `CHAIN_ID` and `OTHER_CHAIN_ID` are REMOTE counterparty chains
    // (destination on send, origin on receive) -- never this contract's own
    // chain. `OTHER_CHAIN_ID` is simply a second remote chain, used by tests
    // that need two lanes at once.
    // / @dev The failure-path gas reserve every fixture controller is
    // / initialized with. See `CrossChainController.initialize`.
    uint256 internal constant MIN_FAILED_MESSAGE_GAS = 45_000;

    uint256 internal constant CHAIN_ID = 10;
    uint256 internal constant OTHER_CHAIN_ID = 20;
    uint256 internal constant GAS_LIMIT = 200_000;
    uint64 internal constant BRIDGE_CHAIN_ID = 1000;
    uint64 internal constant OTHER_BRIDGE_CHAIN_ID = 2000;

    // -------------------------------------------------------------------------
    // Fixture state.
    // -------------------------------------------------------------------------

    CrossChainControllerDAOMock internal daoMock;
    CrossChainController internal controllerImplementation;
    CrossChainController internal controller;
    AdapterMock internal adapterA;
    AdapterMock internal adapterB;
    ERC20Mock internal feeToken;
    ActionExecute internal actionTarget;

    address internal remoteAdapterA;
    address internal remoteAdapterB;
    address internal feeSinkA;
    address internal feeSinkB;
    address internal alice; // holds every permission
    address internal bob; // holds none

    bytes32 internal forwardMessagePermissionId;
    bytes32 internal manageConfigPermissionId;
    bytes32 internal retryMessagePermissionId;
    bytes32 internal cancelMessagePermissionId;
    bytes32 internal sweepPermissionId;
    bytes32 internal pausePermissionId;
    bytes32 internal unpausePermissionId;

    function setUp() public virtual {
        daoMock = new CrossChainControllerDAOMock();
        controllerImplementation = new CrossChainController();
        controller = deployController(address(daoMock), address(daoMock));

        feeToken = new ERC20Mock("Fee", "FEE");
        actionTarget = new ActionExecute();

        remoteAdapterA = makeAddr("remoteAdapterA");
        remoteAdapterB = makeAddr("remoteAdapterB");
        feeSinkA = makeAddr("feeSinkA");
        feeSinkB = makeAddr("feeSinkB");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Default adapters: zero fee, native. Most tests that aren't
        // specifically about fee mechanics use these unmodified so they don't
        // need to fund the controller. `AdapterMock` has no setters -- tests
        // that need different fee/messageId/feeSink/revert behaviour deploy
        // their own dedicated instance instead.
        adapterA = new AdapterMock(address(controller), address(0), 0, bytes32(uint256(1)), feeSinkA, false, false);
        adapterB = new AdapterMock(address(controller), address(0), 0, bytes32(uint256(2)), feeSinkB, false, false);

        forwardMessagePermissionId = Permissions.FORWARD_MESSAGE_PERMISSION_ID;
        manageConfigPermissionId = Permissions.MANAGE_CONTROLLER_CONFIG_PERMISSION_ID;
        retryMessagePermissionId = Permissions.RETRY_MESSAGE_PERMISSION_ID;
        cancelMessagePermissionId = Permissions.CANCEL_MESSAGE_PERMISSION_ID;
        sweepPermissionId = Permissions.SWEEP_PERMISSION_ID;
        pausePermissionId = Permissions.PAUSE_PERMISSION_ID;
        unpausePermissionId = Permissions.UNPAUSE_PERMISSION_ID;

        daoMock.setHasPermission(address(controller), alice, forwardMessagePermissionId, true);
        daoMock.setHasPermission(address(controller), alice, manageConfigPermissionId, true);
        daoMock.setHasPermission(address(controller), alice, retryMessagePermissionId, true);
        daoMock.setHasPermission(address(controller), alice, cancelMessagePermissionId, true);
        daoMock.setHasPermission(address(controller), alice, sweepPermissionId, true);
        daoMock.setHasPermission(address(controller), alice, pausePermissionId, true);
        daoMock.setHasPermission(address(controller), alice, unpausePermissionId, true);
    }

    /// @notice Deploys a controller proxy.
    function deployController(address _dao, address _executor) internal returns (CrossChainController) {
        return CrossChainController(
            payable(ProxyLib.deployUUPSProxy(
                    address(controllerImplementation),
                    abi.encodeCall(CrossChainController.initialize, (IDAO(_dao), _executor, MIN_FAILED_MESSAGE_GAS))
                ))
        );
    }

    // -------------------------------------------------------------------------
    // Config helpers.
    // -------------------------------------------------------------------------

    function _lane(address _local, address _remote) internal pure returns (ICrossChainController.ChainConfig memory) {
        return ICrossChainController.ChainConfig({ localAdapter: _local, remoteAdapter: _remote });
    }

    function _configureLane(uint256 _chainId, address _local, address _remote) internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = _chainId;
        CrossChainController.ChainConfig[] memory configs = new CrossChainController.ChainConfig[](1);
        configs[0] = _lane(_local, _remote);

        vm.prank(alice);
        controller.updateConfig(chainIds, configs);
    }

    // -------------------------------------------------------------------------
    // Envelope helpers.
    // -------------------------------------------------------------------------

    function _emptyActionsPayload() internal pure returns (bytes memory) {
        return abi.encode(new Action[](0));
    }

    /// @dev Builds a `Transaction` envelope carrying `_message` for the given
    ///      origin/nonce. `origin`/`controller`/`destinationChainId` default to
    ///      values that are irrelevant to the receive path (which only decodes
    ///      and hashes), but must be reproduced exactly to predict the txId.
    function _tx(uint256 _nonce, uint256 _originChainId, bytes memory _message)
        internal
        view
        returns (Transaction memory)
    {
        return Transaction({
            nonce: _nonce,
            origin: address(this),
            controller: address(this),
            originChainId: _originChainId,
            destinationChainId: block.chainid,
            message: _message
        });
    }

    /// @dev The encoded envelope bytes handed to `receiveMessage` as `data`.
    function _encodedTx(uint256 _nonce, uint256 _originChainId, bytes memory _message)
        internal
        view
        returns (bytes memory)
    {
        return TransactionLib.encode(_tx(_nonce, _originChainId, _message));
    }

    /// @dev The txId `receiveMessage` will derive for the matching envelope.
    function _txId(uint256 _nonce, uint256 _originChainId, bytes memory _message) internal view returns (bytes32) {
        return TransactionLib.id(_tx(_nonce, _originChainId, _message));
    }

    /// @dev An encoded envelope wrapping an empty `Action[]` (the common case
    ///      for tests that only care about authentication/refcounting, not the
    ///      executed actions).
    function _encodedEmptyTx(uint256 _nonce, uint256 _originChainId) internal view returns (bytes memory) {
        return _encodedTx(_nonce, _originChainId, _emptyActionsPayload());
    }

    // -------------------------------------------------------------------------
    // Storage-slot helpers (verified via
    // `forge inspect src/CrossChainController.sol:CrossChainController storage`).
    //
    // The controller's own variables start at slot 351: everything below that
    // belongs to the upgradeable inheritance chain (`Initializable`,
    // `DaoAuthorizableUpgradeable`, `PluginUUPSUpgradeable`,
    // `PausableUpgradeable` and their `__gap`s). Re-run the command above after
    // ANY change to the base contracts or to the declaration order -- these
    // constants are a hardcoded mirror of the real layout, and a silently stale
    // value makes the collision tests read an untouched gap word and pass
    // vacuously.
    //
    // slot 351 = `_currentTxNonce`, 352 = `_transactions`,
    // 353 = `_retryCutoffs`, 354 = `chainToAdapter`,
    // 355 = `executor` (packed).
    // -------------------------------------------------------------------------

    uint256 internal constant NONCE_SLOT = 351;
    uint256 internal constant TRANSACTION_STATE_SLOT = 352;
    uint256 internal constant RETRY_CUTOFFS_SLOT = 353;
    uint256 internal constant CHAIN_TO_ADAPTER_SLOT = 354;
    uint256 internal constant EXECUTOR_SLOT = 355;

    /// @dev `chainToAdapter[_chainId]` occupies TWO words: word 0 holds
    ///      `localAdapter`; word 1 holds `remoteAdapter`. This returns word 0's
    ///      slot; word 1 is `+ 1`.
    function _chainConfigSlot(uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, CHAIN_TO_ADAPTER_SLOT));
    }

    /// @notice Pins the slot constants above to the real layout.
    /// @dev The storage-collision tests read these slots directly. If the
    ///      inheritance chain shifts them and the constants are not updated,
    ///      those tests would read an untouched word and pass without proving
    ///      anything -- so assert the mapping here, where the failure is
    ///      unambiguous. Each slot is verified by writing through a public
    ///      entry point and observing the word actually move.
    function test_storageSlotConstantsMatchLayout() public {
        // `executor` is set by `initialize`; low 20 bytes of its slot.
        assertEq(
            address(uint160(uint256(vm.load(address(controller), bytes32(EXECUTOR_SLOT))))),
            controller.executor(),
            "EXECUTOR_SLOT stale"
        );

        // `chainToAdapter[CHAIN_ID]` -- word 0 is `localAdapter`.
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        assertEq(
            address(uint160(uint256(vm.load(address(controller), _chainConfigSlot(CHAIN_ID))))),
            address(adapterA),
            "CHAIN_TO_ADAPTER_SLOT stale"
        );

        // `_currentTxNonce` -- moves by exactly one per forward.
        uint256 nonceBefore = uint256(vm.load(address(controller), bytes32(NONCE_SLOT)));
        vm.prank(alice);
        controller.forwardMessage(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
        assertEq(uint256(vm.load(address(controller), bytes32(NONCE_SLOT))), nonceBefore + 1, "NONCE_SLOT stale");

        // `_transactions[txId]` -- set to `Executed` by the delivery above.
        // `state` and `bridgedAt` share the word: `state` is byte 0, so mask it
        // off the packed value rather than comparing the whole word.
        bytes memory encodedTx = _encodedEmptyTx(1, CHAIN_ID);
        vm.prank(address(adapterA));
        controller.receiveMessage(1, encodedTx, CHAIN_ID);
        bytes32 txId = TransactionLib.id(encodedTx);
        assertEq(
            uint256(vm.load(address(controller), keccak256(abi.encode(txId, TRANSACTION_STATE_SLOT)))) & 0xff,
            uint256(controller.getTransaction(txId).state),
            "TRANSACTION_STATE_SLOT stale"
        );
    }
}
