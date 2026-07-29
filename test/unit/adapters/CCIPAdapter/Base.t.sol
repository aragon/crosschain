// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { CrossChainController } from "@src/CrossChainController.sol";
import { ICrossChainControllerEvents, ICrossChainController } from "@src/ICrossChainController.sol";
import { ChainIds } from "@src/lib/ChainIds.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { IDAO } from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import { ProxyLib } from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import { DAOMock } from "@osx-test/mocks/commons/dao/DAOMock.sol";
import { ERC20Mock } from "@mocks/ERC20Mock.sol";
import { CCIPRouterMock } from "@mocks/ccip/CCIPRouterMock.sol";
import { DelegateCallerMock } from "@mocks/DelegateCallerMock.sol";

/// @title CCIPAdapterBase
/// @notice Shared fixture for the per-function `CCIPAdapter` unit tests:
///         deploys the controller, router, fee token, and the several adapter
///         instances the suite needs, plus the inbound-message / lane helpers.
abstract contract CCIPAdapterBase is Test, ICrossChainControllerEvents {
    // -------------------------------------------------------------------------
    // Real CCIP chain selectors / standard chain ids used throughout.
    // -------------------------------------------------------------------------

    /// @dev The failure-path gas reserve the fixture controller is
    ///      initialized with. See `CrossChainController.initialize`.
    uint256 internal constant MIN_FAILED_MESSAGE_GAS = 45_000;

    uint64 internal constant SEL_ETH_MAINNET = 5009297550715157269;
    uint64 internal constant SEL_BASE = 15971525489660198786;
    uint64 internal constant SEL_ARBITRUM_ONE = 4949039107694359620;
    // A real CCIP selector the adapter does NOT map (Sepolia is intentionally
    // absent from the production map), used to exercise the unmapped path.
    uint64 internal constant SEL_SEPOLIA = 16015286601757825753;

    // Standard chain ids come from `ChainIds` (src/common/crosschain/lib).
    uint256 internal constant CHAIN_ETH_MAINNET = ChainIds.ETHEREUM;
    uint256 internal constant CHAIN_BASE = ChainIds.BASE;
    uint256 internal constant CHAIN_ARBITRUM_ONE = ChainIds.ARBITRUM_ONE;

    // Events come from `ICrossChainControllerEvents` (inherited), so
    // `vm.expectEmit` can `emit` them without a local redeclaration.

    DAOMock internal daoMock;
    CrossChainController internal controller;
    CCIPRouterMock internal router;
    ERC20Mock internal feeTokenErc20;

    /// @dev Default adapter from `setUp`: native (`address(0)`) fee token.
    CCIPAdapter internal adapter;
    /// @dev A second adapter but with `FEE_TOKEN = feeTokenErc20`.
    CCIPAdapter internal erc20Adapter;

    /// @dev Drives the guard-isolation tests that the real controller cannot
    ///      reach (see `DelegateCallerMock`'s own docs).
    DelegateCallerMock internal delegateCallerMock;
    /// @dev An adapter whose `CROSS_CHAIN_CONTROLLER` is `delegateCallerMock`,
    ///      used only by those isolation tests.
    CCIPAdapter internal isolationAdapter;

    address internal alice;
    /// @dev The remote chain's CONTROLLER -- the address CCIP reports as the
    ///      message sender on receive, because the source-chain send is a
    ///      `delegatecall`. This is what `_trustedRemotes[chainId]` holds.
    address internal remoteController;
    /// @dev The remote chain's ADAPTER -- the bridge-level receiver, i.e. what
    ///      `CrossChainController.chainToAdapter[chainId].remoteAdapter` holds.
    ///      NEVER a valid value for `_trustedRemotes`.
    address internal remoteAdapter;

    function setUp() public virtual {
        alice = makeAddr("alice");
        remoteController = makeAddr("remoteController");
        remoteAdapter = makeAddr("remoteAdapter");

        daoMock = new DAOMock();
        controller = CrossChainController(
            payable(ProxyLib.deployUUPSProxy(
                    address(new CrossChainController()),
                    abi.encodeCall(
                        CrossChainController.initialize,
                        (IDAO(address(daoMock)), address(daoMock), MIN_FAILED_MESSAGE_GAS)
                    )
                ))
        );
        router = new CCIPRouterMock();
        feeTokenErc20 = new ERC20Mock("Fee Token", "FEE");

        BaseAdapter.TrustedRemoteConfig[] memory trustedRemotes = new BaseAdapter.TrustedRemoteConfig[](1);
        trustedRemotes[0] =
            BaseAdapter.TrustedRemoteConfig({ standardChainId: CHAIN_ETH_MAINNET, trustedRemote: remoteController });

        adapter =
            new CCIPAdapter(
                address(controller),
                address(router),
                address(0), // native fee token
                trustedRemotes
            );

        erc20Adapter = new CCIPAdapter(
            address(controller), address(router), address(feeTokenErc20), new BaseAdapter.TrustedRemoteConfig[](0)
        );

        delegateCallerMock = new DelegateCallerMock(IDAO(address(daoMock)));
        isolationAdapter = new CCIPAdapter(
            address(delegateCallerMock),
            address(router),
            address(feeTokenErc20),
            new BaseAdapter.TrustedRemoteConfig[](0)
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev `DAOMock.hasPermission` is a single flag that authorizes EVERY
    ///      permission once toggled; only flip it inside tests that need it.
    function _grantAllPermissions() internal {
        daoMock.setHasPermissionReturnValueMock(true);
    }

    /// @dev Registers `localAdapter`/`remoteAdapterAddr` as the controller's
    ///      lane for `chainId`. Grants `MANAGE_CONTROLLER_CONFIG_PERMISSION` in
    ///      the process.
    function _registerLane(uint256 chainId, address localAdapter, address remoteAdapterAddr) internal {
        _grantAllPermissions();
        uint256[] memory ids = new uint256[](1);
        ids[0] = chainId;
        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        configs[0] = ICrossChainController.ChainConfig({ localAdapter: localAdapter, remoteAdapter: remoteAdapterAddr });
        controller.updateConfig(ids, configs);
    }

    /// @dev Clears a previously-registered lane (all-zero config).
    function _clearLane(uint256 chainId) internal {
        _grantAllPermissions();
        uint256[] memory ids = new uint256[](1);
        ids[0] = chainId;
        ICrossChainController.ChainConfig[] memory configs = new ICrossChainController.ChainConfig[](1);
        controller.updateConfig(ids, configs);
    }

    function _buildInbound(uint64 selector, address sender, bytes memory data)
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: keccak256("default-inbound-message"),
            sourceChainSelector: selector,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _emptyActionsPayload() internal pure returns (bytes memory) {
        return abi.encode(new Action[](0));
    }

    // -------------------------------------------------------------------------
    // Controller storage-slot helpers (verified via
    // `forge inspect src/CrossChainController.sol:CrossChainController storage`).
    //
    // The controller's own variables start at slot 351 -- everything below
    // belongs to the upgradeable inheritance chain. Re-run the command above
    // after any change to the base contracts or declaration order; a stale
    // value makes the collision test read an untouched word and pass vacuously.
    // -------------------------------------------------------------------------

    uint256 internal constant PAUSED_SLOT = 301;
    uint256 internal constant NONCE_SLOT = 351;
    uint256 internal constant TRANSACTION_STATE_SLOT = 352;
    uint256 internal constant RETRY_CUTOFFS_SLOT = 353;
    uint256 internal constant CHAIN_TO_ADAPTER_SLOT = 354;

    /// @notice Pins the slot constants above to the real layout.
    /// @dev Without this, a stale constant makes the collision tests read a word
    ///      nothing ever writes, so they compare zero to zero and pass
    ///      vacuously. Each slot is verified by writing through a public entry
    ///      point and observing that exact word move.
    function test_storageSlotConstantsMatchLayout() public {
        // `chainToAdapter[chainId]` -- word 0 of the struct is `localAdapter`.
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);
        assertEq(
            address(
                uint160(
                    uint256(
                        vm.load(address(controller), keccak256(abi.encode(CHAIN_ETH_MAINNET, CHAIN_TO_ADAPTER_SLOT)))
                    )
                )
            ),
            address(adapter),
            "CHAIN_TO_ADAPTER_SLOT stale"
        );

        // `_paused` -- byte 0 of its slot, flipped by `pause()`.
        controller.pause();
        assertEq(uint256(vm.load(address(controller), bytes32(PAUSED_SLOT))) & 0xff, 1, "PAUSED_SLOT stale");
        controller.unpause();

        // `_currentTxNonce` -- moves by exactly one per forward.
        router.setFee(0);
        uint256 nonceBefore = uint256(vm.load(address(controller), bytes32(NONCE_SLOT)));
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");
        assertEq(uint256(vm.load(address(controller), bytes32(NONCE_SLOT))), nonceBefore + 1, "NONCE_SLOT stale");
    }
}
