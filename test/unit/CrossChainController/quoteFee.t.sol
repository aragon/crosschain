// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { CrossChainControllerBase } from "./Base.t.sol";
import { Errors } from "@src/lib/Errors.sol";
import { Transaction, TransactionLib } from "@src/lib/Transaction.sol";
import { AdapterMock } from "@mocks/AdapterMock.sol";
import { QuoteEchoAdapterStub } from "@mocks/QuoteEchoAdapterStub.sol";

contract CrossChainControllerQuoteFeeTest is CrossChainControllerBase {
    function test_revertsIfLaneNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ADAPTER_NOT_CONFIGURED.selector, CHAIN_ID));
        controller.quoteFee(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
    }

    function test_returnsAdapterFeeTokenAndFee() public {
        AdapterMock feeAdapter =
            new AdapterMock(address(controller), address(0), 1 ether, bytes32(uint256(3)), feeSinkA, false, false);
        _configureLane(CHAIN_ID, address(feeAdapter), remoteAdapterA);

        (address feeToken, uint256 fee,) = controller.quoteFee(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());

        assertEq(feeToken, address(0));
        assertEq(fee, 1 ether);
    }

    function test_availableReportsNativeBalanceForNativeFeeToken() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);
        vm.deal(address(controller), 3 ether);

        (,, uint256 available) = controller.quoteFee(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());

        assertEq(available, 3 ether);
    }

    function test_availableReportsErc20BalanceForErc20FeeToken() public {
        AdapterMock erc20FeeAdapter = new AdapterMock(
            address(controller), address(feeToken), 1 ether, bytes32(uint256(3)), feeSinkA, false, false
        );
        _configureLane(CHAIN_ID, address(erc20FeeAdapter), remoteAdapterA);

        feeToken.setBalance(address(controller), 5 ether);
        // Native balance must NOT leak into an ERC20 quote.
        vm.deal(address(controller), 9 ether);

        (address quotedToken,, uint256 available) = controller.quoteFee(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());

        assertEq(quotedToken, address(feeToken));
        assertEq(available, 5 ether);
    }

    /// @dev The core documented guarantee: `quoteFee` quotes the SAME bytes
    ///      `forwardMessage` will send, including the nonce mirror
    ///      (`_currentTxNonce + 1` vs `++_currentTxNonce`). The echo stub
    ///      fingerprints the envelope it receives into the returned fee, so the
    ///      quote can be compared against a locally reconstructed envelope --
    ///      and against the txId the subsequent forward actually derives.
    function test_quotesTheExactEnvelopeForwardMessageWillSend() public {
        QuoteEchoAdapterStub echoAdapter = new QuoteEchoAdapterStub();
        _configureLane(CHAIN_ID, address(echoAdapter), remoteAdapterA);

        bytes memory message = _emptyActionsPayload();
        bytes memory expectedEnvelope = TransactionLib.encode(
            Transaction({
                nonce: 1, // fresh controller: the next forward uses ++nonce = 1
                origin: alice,
                controller: address(controller),
                originChainId: block.chainid,
                destinationChainId: CHAIN_ID,
                message: message
            })
        );

        vm.prank(alice);
        (, uint256 quotedFingerprint,) = controller.quoteFee(CHAIN_ID, GAS_LIMIT, message);
        assertEq(quotedFingerprint, uint256(keccak256(expectedEnvelope)), "quoted envelope differs from expectation");

        // The forward must derive its txId from those very bytes.
        vm.prank(alice);
        bytes32 txId = controller.forwardMessage(CHAIN_ID, GAS_LIMIT, message);
        assertEq(txId, TransactionLib.id(expectedEnvelope), "forwarded envelope differs from the quoted one");

        // After the nonce was consumed, the next quote mirrors nonce 2.
        bytes memory nextEnvelope = TransactionLib.encode(
            Transaction({
                nonce: 2,
                origin: alice,
                controller: address(controller),
                originChainId: block.chainid,
                destinationChainId: CHAIN_ID,
                message: message
            })
        );
        vm.prank(alice);
        (, uint256 nextFingerprint,) = controller.quoteFee(CHAIN_ID, GAS_LIMIT, message);
        assertEq(nextFingerprint, uint256(keccak256(nextEnvelope)), "quote must track the advanced nonce");
    }

    function test_bubblesAdapterQuoteRevert() public {
        AdapterMock revertingAdapter =
            new AdapterMock(address(controller), address(0), 0, bytes32(uint256(3)), feeSinkA, false, true);
        _configureLane(CHAIN_ID, address(revertingAdapter), remoteAdapterA);

        vm.expectRevert("AdapterMock: quoteFee reverted");
        controller.quoteFee(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
    }

    /// @dev Deliberately no `whenNotPaused`: quoting is a read and must keep
    ///      working while sends are halted.
    function test_quoteWorksWhilePaused() public {
        _configureLane(CHAIN_ID, address(adapterA), remoteAdapterA);

        vm.prank(alice);
        controller.pause();

        (address quotedToken, uint256 fee,) = controller.quoteFee(CHAIN_ID, GAS_LIMIT, _emptyActionsPayload());
        assertEq(quotedToken, address(0));
        assertEq(fee, 0);
    }
}
