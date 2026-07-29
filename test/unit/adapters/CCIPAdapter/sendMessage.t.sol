// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CCIPAdapterBase } from "./Base.t.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { CCIPAdapter } from "@src/adapters/CCIP/CCIPAdapter.sol";
import { BaseAdapter } from "@src/adapters/BaseAdapter.sol";
import { IBaseAdapter } from "@src/adapters/IBaseAdapter.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";
import { ERC20Mock } from "@mocks/ERC20Mock.sol";
import { CCIPRouterMock } from "@mocks/ccip/CCIPRouterMock.sol";
import { TrustedRemoteWritingCCIPAdapter } from "@mocks/ccip/TrustedRemoteWritingCCIPAdapter.sol";
import { OversizedSelectorCCIPAdapter } from "@mocks/ccip/OversizedSelectorCCIPAdapter.sol";

contract CCIPAdapterSendMessageTest is CCIPAdapterBase {
    // -------------------------------------------------------------------------
    // `sendMessage` can ONLY be reached via `delegatecall` from the controller.
    // -------------------------------------------------------------------------

    function test_revertsIfCalledDirectly_evenWhenCallerIsTheController() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.SEND_PATH_NOT_DELEGATECALLED.selector, address(adapter)));
        vm.prank(address(controller));
        adapter.sendMessage(remoteAdapter, SEL_ETH_MAINNET, 200_000, "");
    }

    function test_revertsIfCalledDirectlyByAnybody() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.SEND_PATH_NOT_DELEGATECALLED.selector, address(adapter)));
        vm.prank(alice);
        adapter.sendMessage(remoteAdapter, SEL_ETH_MAINNET, 200_000, "");
    }

    function test_revertsIfReceiverIsZero() public {
        bytes memory data = abi.encodeCall(IBaseAdapter.sendMessage, (address(0), SEL_ETH_MAINNET, 200_000, bytes("")));

        vm.expectRevert(Errors.ZERO_ADDRESS.selector);
        delegateCallerMock.delegateCall(address(isolationAdapter), data);
    }

    function test_revertsIfNativeValueSentWhileErc20FeeTokenConfigured() public {
        bytes memory data =
            abi.encodeCall(IBaseAdapter.sendMessage, (remoteAdapter, CHAIN_ETH_MAINNET, 200_000, bytes("")));

        vm.expectRevert(Errors.UNEXPECTED_NATIVE_VALUE.selector);
        delegateCallerMock.delegateCall{ value: 1 ether }(address(isolationAdapter), data);
    }

    /// @dev `toNativeChainId` is `virtual`; the built-in map only ever returns
    ///      `uint64`-sized CCIP selectors, so the `SafeCast.toUint64` on the
    ///      send path can only trip via a subclass whose map returns a wider
    ///      value. The cast must revert rather than silently truncate the
    ///      selector and dispatch to the wrong lane.
    function test_revertsIfNativeChainIdDoesNotFitUint64() public {
        OversizedSelectorCCIPAdapter oversizedAdapter =
            new OversizedSelectorCCIPAdapter(address(controller), address(router));
        _registerLane(CHAIN_ETH_MAINNET, address(oversizedAdapter), remoteAdapter);

        vm.expectRevert("SafeCast: value doesn't fit in 64 bits");
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(router.ccipSendCallCount(), 0, "no message may be dispatched with a truncated selector");
    }

    /// @dev The controller registers lanes without consulting the adapter's
    ///      chain-id map, so a lane can exist for a standard chain id the
    ///      adapter cannot translate into a CCIP selector. The send must then
    ///      revert with `UNKNOWN_CHAIN_ID` instead of reaching the router.
    function test_revertsIfDestinationChainIdUnknownToAdapter() public {
        uint256 unknownChainId = 42;
        _registerLane(unknownChainId, address(adapter), remoteAdapter);

        vm.expectRevert(abi.encodeWithSelector(Errors.UNKNOWN_CHAIN_ID.selector, unknownChainId));
        controller.forwardMessage(unknownChainId, 200_000, "");

        assertEq(router.ccipSendCallCount(), 0, "no message may be dispatched for an unmapped chain id");
    }

    // -------------------------------------------------------------------------
    // The bridge must still serve the destination chain.
    // -------------------------------------------------------------------------

    /// @dev A locally configured lane is not proof CCIP still serves the
    ///      destination: support can be dropped after `updateConfig` ran.
    function test_revertsIfRouterDoesNotSupportDestinationChain() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);
        vm.deal(address(controller), 1 ether);

        router.setChainSupported(false);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DESTINATION_CHAIN_ID_NOT_SUPPORTED.selector, uint256(SEL_ETH_MAINNET))
        );
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(router.ccipSendCallCount(), 0, "no message may be dispatched to an unsupported chain");
    }

    function test_sendSucceedsWhenRouterSupportsDestinationChain() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);
        uint256 feeAmount = 0.01 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), feeAmount);

        router.setChainSupported(true);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(router.ccipSendCallCount(), 1);
        assertEq(router.lastDestChainSelector(), SEL_ETH_MAINNET);
    }

    // -------------------------------------------------------------------------
    // Fees -- the controller pays, the adapter never holds funds.
    // -------------------------------------------------------------------------

    function test_erc20Fee_approvesRouterAndRouterPullsExactFee() public {
        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter);
        uint256 feeAmount = 3 ether;
        router.setFee(feeAmount);
        feeTokenErc20.setBalance(address(controller), feeAmount);

        assertEq(feeTokenErc20.balanceOf(address(controller)), feeAmount);

        // `forwardMessage` returns the txId; the router's messageId is surfaced
        // via the `MessageForwarded` event. Pin messageId (topic 2), ignore the
        // txId topic and the non-indexed data.
        vm.expectEmit(true, true, false, false, address(controller));
        emit MessageForwarded(
            CHAIN_ETH_MAINNET, uint256(router.nextMessageId()), bytes32(0), "", address(0), address(0), 0, 0
        );

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "hello");

        assertEq(router.ccipSendCallCount(), 1);
        assertEq(feeTokenErc20.balanceOf(address(router)), feeAmount, "router must have pulled the fee");
    }

    function test_erc20Fee_leavesZeroStandingAllowanceOnControllerAfterSend() public {
        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter);
        uint256 feeAmount = 3 ether;
        router.setFee(feeAmount);
        feeTokenErc20.setBalance(address(controller), feeAmount);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(feeTokenErc20.allowance(address(controller), address(router)), 0);
    }

    function test_erc20Fee_TakesTheRequiredAndLeavesRemaining() public {
        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter);
        uint256 feeAmount = 1 ether;
        router.setFee(feeAmount);
        feeTokenErc20.setBalance(address(controller), 3 ether);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(feeTokenErc20.allowance(address(controller), address(router)), 0);
        assertEq(feeTokenErc20.balanceOf(address(controller)), 2 ether);
    }

    function test_erc20Fee_revertsIfControllerBalanceInsufficient() public {
        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter);
        uint256 feeAmount = 1 ether;
        uint256 available = 0.4 ether;
        router.setFee(feeAmount);
        feeTokenErc20.setBalance(address(controller), available);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.INSUFFICIENT_FEE_BALANCE.selector, address(feeTokenErc20), feeAmount, available
            )
        );
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");
    }

    function test_nativeFee_paysExactFeeFromControllerBalance() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);
        uint256 feeAmount = 0.05 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), feeAmount);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(router.lastMsgValue(), feeAmount, "router must receive exactly the quoted fee");
        assertEq(address(controller).balance, 0);
        assertEq(address(adapter).balance, 0, "adapter must never hold native funds");
        assertEq(address(router).balance, feeAmount, "router must hold native funds");
    }

    function test_nativeFee_revertsIfControllerBalanceInsufficient() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);
        uint256 feeAmount = 1 ether;
        uint256 available = 0.5 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), available);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.INSUFFICIENT_FEE_BALANCE.selector, address(0), feeAmount, available)
        );
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");
    }

    function test_nativeFee_TakesTheRequiredAndLeavesRemaining() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);
        uint256 feeAmount = 1 ether;
        uint256 available = 3 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), available);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");
        assertEq(address(controller).balance, 2 ether);
    }

    // -------------------------------------------------------------------------
    // End-to-end: controller.forwardMessage -> [delegatecall] adapter -> router.
    // -------------------------------------------------------------------------

    function test_endToEnd_routesThroughAdapterToRouter() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);

        uint256 feeAmount = 0.02 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), feeAmount);

        bytes32 expectedMessageId = keccak256("expected-message-id");
        router.setNextMessageId(expectedMessageId);

        bytes memory payload = _emptyActionsPayload();
        uint256 gasLimit = 300_000;

        // `forwardMessage` stamps nonce = ++_currentTxNonce (1 on first send),
        // origin = msg.sender (this test), controller = the controller,
        // originChainId = block.chainid. The txId is that envelope's id.
        Transaction memory expectedTx = Transaction({
            nonce: 1,
            origin: address(this),
            controller: address(controller),
            originChainId: block.chainid,
            destinationChainId: CHAIN_ETH_MAINNET,
            message: payload
        });
        bytes32 expectedTxId = TransactionLib.id(expectedTx);
        bytes memory expectedEnvelope = TransactionLib.encode(expectedTx);

        vm.expectEmit(true, true, true, true, address(controller));
        emit MessageForwarded(
            CHAIN_ETH_MAINNET,
            uint256(expectedMessageId),
            expectedTxId,
            expectedEnvelope,
            address(adapter),
            remoteAdapter,
            gasLimit,
            feeAmount
        );

        bytes32 txId = controller.forwardMessage(CHAIN_ETH_MAINNET, gasLimit, payload);
        assertEq(txId, expectedTxId);

        address decodedReceiver = abi.decode(router.lastReceiver(), (address));
        assertEq(decodedReceiver, remoteAdapter, "router must target the remote adapter");
        assertEq(router.lastData(), expectedEnvelope, "bridge data must be the exact encoded envelope");
        assertEq(router.lastFeeToken(), address(0));
        assertEq(router.lastDestChainSelector(), SEL_ETH_MAINNET);
        assertEq(router.lastMsgValue(), feeAmount);
        assertEq(
            router.lastCaller(), address(controller), "CCIP must see the controller as the sender under delegatecall"
        );

        bytes memory expectedExtraArgs =
            Client._argsToBytes(Client.GenericExtraArgsV2({ gasLimit: gasLimit, allowOutOfOrderExecution: true }));
        assertEq(router.lastExtraArgs(), expectedExtraArgs, "extraArgs must encode the requested gas limit");
    }

    // -------------------------------------------------------------------------
    // Immutables resolve correctly under `delegatecall`.
    // -------------------------------------------------------------------------

    function test_immutables_feeTokenAndRouterSurviveDelegatecall_notMisreadAsControllerStorage() public {
        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter);

        uint256 feeAmount = 2 ether;
        router.setFee(feeAmount);
        feeTokenErc20.setBalance(address(controller), feeAmount);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(router.lastFeeToken(), address(feeTokenErc20), "immutable FEE_TOKEN must survive delegatecall");
        assertEq(router.lastCaller(), address(controller), "CCIP_ROUTER must see the controller as caller");
    }

    /// @dev Two adapters, two ERC20 fee tokens, two routers: a send through
    ///      lane A must resolve adapter A's OWN immutables and hit ONLY router A.
    function test_immutables_twoAdaptersRouteExclusivelyToTheirOwnRouterAndFeeToken() public {
        CCIPRouterMock routerB = new CCIPRouterMock();
        ERC20Mock feeTokenB = new ERC20Mock("Fee Token B", "FEEB");
        CCIPAdapter adapterB = new CCIPAdapter(
            address(controller), address(routerB), address(feeTokenB), new BaseAdapter.TrustedRemoteConfig[](0)
        );

        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter); // -> router (lane A)
        _registerLane(CHAIN_BASE, address(adapterB), remoteAdapter); // -> routerB (lane B)

        router.setFee(1 ether);
        routerB.setFee(2 ether);
        feeTokenErc20.setBalance(address(controller), 1 ether);
        feeTokenB.setBalance(address(controller), 2 ether);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        assertEq(router.ccipSendCallCount(), 1);
        assertEq(router.lastFeeToken(), address(feeTokenErc20));
        assertEq(routerB.ccipSendCallCount(), 0, "lane A's send must not touch router B at all");
    }

    // -------------------------------------------------------------------------
    // No storage collision with the controller.
    // -------------------------------------------------------------------------

    /// @dev Snapshots the controller's storage byte-for-byte around a successful
    ///      `forwardMessage`, using the REAL `CCIPAdapter`. The slot constants
    ///      live in `Base.t.sol` and are pinned to the real layout by
    ///      `test_storageSlotConstantsMatchLayout` -- a stale one would make
    ///      the assertions below read an untouched word and pass vacuously.
    ///      The nonce slot legitimately increments on send (asserted
    ///      separately); everything else must be untouched, as must the
    ///      adapter's own (separate-address) storage.
    function test_doesNotCollideWithControllerStorage() public {
        _registerLane(CHAIN_ETH_MAINNET, address(adapter), remoteAdapter);

        uint256 feeAmount = 0.02 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), feeAmount);

        bytes32 chainConfigSlotA = keccak256(abi.encode(CHAIN_ETH_MAINNET, CHAIN_TO_ADAPTER_SLOT));
        bytes32 chainConfigSlotB = bytes32(uint256(chainConfigSlotA) + 1);

        bytes32 pausedBefore = vm.load(address(controller), bytes32(PAUSED_SLOT));
        bytes32 nonceBefore = vm.load(address(controller), bytes32(NONCE_SLOT));
        bytes32 txStateBefore = vm.load(address(controller), bytes32(TRANSACTION_STATE_SLOT));
        bytes32 chainToAdapterBefore = vm.load(address(controller), bytes32(CHAIN_TO_ADAPTER_SLOT));
        bytes32 chainConfigABefore = vm.load(address(controller), chainConfigSlotA);
        bytes32 chainConfigBBefore = vm.load(address(controller), chainConfigSlotB);

        address trustedRemoteBefore = adapter.trustedRemote(CHAIN_ETH_MAINNET);
        uint256 nativeChainIdBefore = adapter.toNativeChainId(CHAIN_ETH_MAINNET);

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        // `_currentTxNonce` is the one word a send legitimately mutates: it
        // must have incremented by exactly one.
        assertEq(
            vm.load(address(controller), bytes32(NONCE_SLOT)),
            bytes32(uint256(nonceBefore) + 1),
            "nonce must increment by exactly one"
        );
        assertEq(vm.load(address(controller), bytes32(PAUSED_SLOT)), pausedBefore, "_paused slot mutated by send");
        assertEq(
            vm.load(address(controller), bytes32(TRANSACTION_STATE_SLOT)),
            txStateBefore,
            "_transactions base slot mutated by send"
        );
        assertEq(
            vm.load(address(controller), bytes32(CHAIN_TO_ADAPTER_SLOT)),
            chainToAdapterBefore,
            "chainToAdapter base slot mutated by send"
        );
        assertEq(
            vm.load(address(controller), chainConfigSlotA),
            chainConfigABefore,
            "chainToAdapter[chainId] slot A mutated by send"
        );
        assertEq(
            vm.load(address(controller), chainConfigSlotB),
            chainConfigBBefore,
            "chainToAdapter[chainId] slot B mutated by send"
        );

        assertEq(adapter.trustedRemote(CHAIN_ETH_MAINNET), trustedRemoteBefore, "adapter's own storage touched by send");
        assertEq(
            adapter.toNativeChainId(CHAIN_ETH_MAINNET),
            nativeChainIdBefore,
            "adapter's own selector-map storage touched by send"
        );
    }

    function test_sendPathWritingTrustedRemotes_corruptsControllerStorageNotTheAdapters() public {
        TrustedRemoteWritingCCIPAdapter statefulAdapter =
            new TrustedRemoteWritingCCIPAdapter(address(controller), address(router));
        _registerLane(CHAIN_ETH_MAINNET, address(statefulAdapter), remoteAdapter);

        uint256 feeAmount = 0.01 ether;
        router.setFee(feeAmount);
        vm.deal(address(controller), feeAmount);

        // Where `_trustedRemotes[CHAIN_ETH_MAINNET]` resolves when slot 0 is
        // the controller's.
        bytes32 aliasedSlot = keccak256(abi.encode(CHAIN_ETH_MAINNET, uint256(0)));
        assertEq(vm.load(address(controller), aliasedSlot), bytes32(0));

        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");

        // The controller passes `config.remoteAdapter` as the receiver, so
        // that is the value the misdirected write stores.
        assertEq(
            vm.load(address(controller), aliasedSlot),
            bytes32(uint256(uint160(remoteAdapter))),
            "the trusted-remote write must land in the controller's storage"
        );
        assertEq(
            statefulAdapter.trustedRemote(CHAIN_ETH_MAINNET),
            address(0),
            "the adapter's own trusted-remote mapping must stay untouched"
        );
    }

    // -------------------------------------------------------------------------
    // Fee-token immutability trade-off: no `setFeeToken`.
    // -------------------------------------------------------------------------

    function test_feeTokenRotation_requiresDeployingANewAdapterAndRepointingTheLane() public {
        ERC20Mock newFeeToken = new ERC20Mock("New Fee Token", "NEWFEE");
        CCIPAdapter newAdapter = new CCIPAdapter(
            address(controller), address(router), address(newFeeToken), new BaseAdapter.TrustedRemoteConfig[](0)
        );

        // Old lane, old fee token: works today.
        _registerLane(CHAIN_ETH_MAINNET, address(erc20Adapter), remoteAdapter);
        assertTrue(controller.isRegisteredLocalAdapter(address(erc20Adapter), CHAIN_ETH_MAINNET));

        router.setFee(1 ether);
        feeTokenErc20.setBalance(address(controller), 1 ether);
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");
        assertEq(router.lastFeeToken(), address(feeTokenErc20));

        // Rotate: repoint the SAME chain id at the new adapter/fee token.
        _registerLane(CHAIN_ETH_MAINNET, address(newAdapter), remoteAdapter);

        assertFalse(
            controller.isRegisteredLocalAdapter(address(erc20Adapter), CHAIN_ETH_MAINNET),
            "old adapter must lose the right to call receiveMessage once its lane is repointed"
        );
        assertTrue(controller.isRegisteredLocalAdapter(address(newAdapter), CHAIN_ETH_MAINNET));

        router.setFee(1 ether);
        newFeeToken.setBalance(address(controller), 1 ether);
        controller.forwardMessage(CHAIN_ETH_MAINNET, 200_000, "");
        assertEq(router.lastFeeToken(), address(newFeeToken), "send must now use the new adapter's fee token");
    }
}

