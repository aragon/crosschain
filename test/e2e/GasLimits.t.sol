// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Errors } from "@src/lib/Errors.sol";

import { CrossChainE2EBase } from "./Base.sol";
import { GasBurnerTarget } from "@mocks/GasBurnerTarget.sol";

/// @title CrossChainGasLimitsE2ETest
/// @notice The three gas regimes an inbound delivery can land in, and which
///         recovery path each one leaves open.
///
/// @dev THE THREE REGIMES.
///
///      1. PLENTY -- the payload runs and the message is `Executed`.
///
///      2. TOO LITTLE FOR THE PAYLOAD, enough for the bookkeeping -- the failure
///         is CAUGHT and stored as `Delivered`. CCIP considers the message
///         done, so the only exit is `retryMessage`, which is PERMISSIONED.
///
///      3. TOO LITTLE FOR EVEN THAT -- the whole `ccipReceive` reverts, nothing
///         is stored, and CCIP leaves the message manually executable BY
///         ANYONE.
///
///      Regime 3 is the friendlier failure: it needs no permission from us.
///      Regime 2 needs an ops account holding `RETRY_MESSAGE_PERMISSION`.
///
///      WHY `minFailedMessageGas` MATTERS HERE. Without a reserve, regime 2 is
///      a narrow accident of the 63/64 rule: the payload gets 63/64 of what is
///      left and the `catch` keeps 1/64, which at these call depths is a few
///      hundred gas -- far short of an `SSTORE` plus an event. So a payload that
///      runs out of gas takes the whole delivery down with it and the message
///      falls into regime 3. `minFailedMessageGas` withholds a fixed 45,000 gas
///      BEFORE the payload runs, which turns regime 2 from an accident into a
///      guarantee. `test_gas_withoutTheReserveAnExhaustingPayloadLosesTheRecord`
///      is the A/B proof of that, and is the reason the reserve exists.
contract CrossChainGasLimitsE2ETest is CrossChainE2EBase {
    /// @dev A payload whose single action consumes every unit of gas it is
    ///      given, so the inner call always ends in `OutOfGas` rather than a
    ///      normal revert. A plain reverting target cannot produce this: it
    ///      returns the unused gas instead of burning it.
    function _burnEverythingPayload(GasBurnerTarget _burner) internal pure returns (bytes memory) {
        return _actionPayload(address(_burner), 0, abi.encodeCall(GasBurnerTarget.burn, ()));
    }

    // -------------------------------------------------------------------------
    // The gas limit reaches the destination unchanged.
    // -------------------------------------------------------------------------

    /// @notice The limit requested at send time is the limit the destination is
    ///         given, having survived the `extraArgs` round trip.
    /// @dev If `GenericExtraArgsV2` were encoded with the wrong tag or the wrong
    ///      field order, CCIP would silently fall back to its 200k default and
    ///      every one of these regimes would shift underneath us.
    function test_gas_requestedLimitSurvivesTheExtraArgsRoundTrip() public {
        _forwardViaProposal(origin, destination, 777_000, _cancelPayload(destination));

        assertEq(
            origin.router.sentAt(0).gasLimit, 777_000, "the destination must receive the gas limit that was requested"
        );
    }

    // -------------------------------------------------------------------------
    // Regime 1: enough gas.
    // -------------------------------------------------------------------------

    /// @notice A generous limit executes the payload.
    function test_gas_sufficientLimitExecutes() public {
        bytes32 txId = _forwardViaProposal(origin, destination, 2_000_000, _cancelPayload(destination));

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success);
        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    // -------------------------------------------------------------------------
    // Regime 2: caught, stored, permissioned recovery.
    // -------------------------------------------------------------------------

    /// @notice An action that burns every unit of gas it is handed is CAUGHT and
    ///         stored, because the reserve is withheld before it ever runs.
    /// @dev The griefing question: can a hostile destination action make the
    ///      controller lose the message? No -- the `catch` is guaranteed enough
    ///      gas to record it, so the worst case is a permissioned retry or a
    ///      cancel, never a message that silently disappears.
    function test_gas_actionBurningAllGasIsCaughtAndStored() public {
        GasBurnerTarget burner = new GasBurnerTarget();

        bytes32 txId = _forwardViaProposal(origin, destination, 2_000_000, _burnEverythingPayload(burner));

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the BRIDGE delivery succeeded -- CCIP considers this message done");
        _assertDelivered(destination, txId);
        assertFalse(burner.entered(), "the burn reverted, so none of its writes stuck");
    }

    /// @notice A message stuck behind a gas-burning action is still reachable by
    ///         the ops levers: it can be cancelled for good.
    /// @dev Together with the test above this is the whole griefing story. The
    ///      message cannot be retried into success (the action burns whatever it
    ///      is given, every time), but it can be neutralised, which is what
    ///      matters: it never blocks the lane and never sits in limbo.
    function test_gas_burnedMessageStaysReachableAndCanBeCancelled() public {
        GasBurnerTarget burner = new GasBurnerTarget();

        bytes32 txId = _forwardViaProposal(origin, destination, 2_000_000, _burnEverythingPayload(burner));

        _deliverNext(origin, destination);
        _assertDelivered(destination, txId);

        _on(destination);
        vm.prank(address(destination.dao));
        destination.controller.cancelMessage(txId);
        _on(origin);

        _assertCancelled(destination, txId);
    }

    /// @notice WITHOUT the reserve, the very same delivery loses its record.
    /// @dev The A/B proof that `minFailedMessageGas` is load-bearing. Setting it
    ///      to zero puts the `catch` back on the 1/64 the EVM retains, and the
    ///      consequence is operational, not cosmetic: `retryMessage` and
    ///      `cancelMessage` both require a stored record, so with no reserve
    ///      neither can touch the message and only the bridge's own manual
    ///      execution can.
    ///
    ///      WHY 150,000. The retained 1/64 SCALES with the limit, so the reserve
    ///      only decides the outcome below the point where 1/64 happens to cover
    ///      an `SSTORE` plus an event on its own. Measured on this payload, 150k
    ///      is decisively inside that band (fails with no reserve, stores with
    ///      one) while by 300k the 1/64 already suffices either way. The FIXED
    ///      45,000 is what makes the guarantee hold at every limit rather than
    ///      only the large ones -- which is the whole point, since a sender
    ///      choosing a tight limit is exactly the case that needs it.
    ///
    ///      If this fails after a toolchain bump, re-measure the band rather
    ///      than deleting the test: the property is real, only the number moves.
    function test_gas_withoutTheReserveAnExhaustingPayloadLosesTheRecord() public {
        uint256 tightLimit = 150_000;

        vm.prank(address(destination.dao));
        destination.controller.updateMinFailedMessageGas(0);

        GasBurnerTarget burner = new GasBurnerTarget();

        bytes32 txId = _forwardViaProposal(origin, destination, tightLimit, _burnEverythingPayload(burner));
        bytes memory encodedTx = _queuedPayload(origin, 0);

        (, bool success) = _deliverNext(origin, destination);

        assertFalse(success, "with no reserve the whole delivery reverts");
        _assertUnknown(destination, txId);

        // And with nothing stored, neither ops lever can reach it.
        _on(destination);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        destination.controller.retryMessage(encodedTx);

        vm.prank(address(destination.dao));
        vm.expectRevert(abi.encodeWithSelector(Errors.MESSAGE_ALREADY_EXECUTED_OR_NOT_EXISTS.selector, txId));
        destination.controller.cancelMessage(txId);
        _on(origin);
    }

    /// @notice WITH the reserve, that same 150,000-gas delivery is stored.
    /// @dev The other half of the A/B. Same payload, same limit, same everything
    ///      except `minFailedMessageGas`, and the message stays reachable.
    function test_gas_withTheReserveTheSameTightDeliveryIsStored() public {
        uint256 tightLimit = 150_000;

        assertEq(destination.controller.minFailedMessageGas(), MIN_FAILED_MESSAGE_GAS, "the reserve is in force");

        GasBurnerTarget burner = new GasBurnerTarget();

        bytes32 txId = _forwardViaProposal(origin, destination, tightLimit, _burnEverythingPayload(burner));

        (, bool success) = _deliverNext(origin, destination);

        assertTrue(success, "the reserve keeps the delivery itself alive");
        _assertDelivered(destination, txId);
    }

    // -------------------------------------------------------------------------
    // Regime 3: bridge-level failure -- nothing stored, anyone can re-execute.
    // -------------------------------------------------------------------------

    /// @notice A limit too small for even the bookkeeping reverts the whole
    ///         delivery, stores nothing, and stays manually executable.
    /// @dev This is the GOOD failure mode: CCIP marks the message failed and
    ///      anyone may re-execute it with more gas, no permission required.
    function test_gas_tooLittleForTheDeliveryLeavesNothingStored() public {
        bytes32 txId = _forwardViaProposal(origin, destination, 30_000, _cancelPayload(destination));
        bytes32 messageId = origin.router.messageIdAt(0);

        (, bool success) = _deliverNext(origin, destination);

        assertFalse(success, "the delivery itself must fail");
        _assertUnknown(destination, txId);
        assertEq(destination.target.cancellations(), 0);

        // Manual execution with a workable limit -- permissionless.
        assertTrue(_manualExecute(origin, destination, messageId, 500_000), "manual re-execution must succeed");
        _assertExecuted(destination, txId);
        assertEq(destination.target.cancellations(), 1);
    }

    /// @notice A zero gas limit is the degenerate case of the same regime.
    /// @dev Our payload is never empty, so CCIP does call the receiver -- with
    ///      no gas at all. Nothing is stored, and the message is recoverable.
    function test_gas_zeroLimitFailsAtTheBridgeAndStaysRecoverable() public {
        bytes32 txId = _forwardViaProposal(origin, destination, 0, _cancelPayload(destination));
        bytes32 messageId = origin.router.messageIdAt(0);

        (, bool success) = _deliverNext(origin, destination);

        assertFalse(success);
        _assertUnknown(destination, txId);

        assertTrue(_manualExecute(origin, destination, messageId, 500_000));
        _assertExecuted(destination, txId);
    }

    /// @notice Manual execution that is STILL under-gassed changes nothing and
    ///         can be attempted again.
    function test_gas_underGassedManualExecutionCanBeRetried() public {
        bytes32 txId = _forwardViaProposal(origin, destination, 30_000, _cancelPayload(destination));
        bytes32 messageId = origin.router.messageIdAt(0);

        _deliverNext(origin, destination);
        _assertUnknown(destination, txId);

        assertFalse(_manualExecute(origin, destination, messageId, 40_000), "still not enough");
        _assertUnknown(destination, txId);

        assertTrue(_manualExecute(origin, destination, messageId, 500_000));
        _assertExecuted(destination, txId);
    }

    /// @notice The origin accepts a gas limit far too small to execute anything,
    ///         and still charges the full fee.
    /// @dev `_gasLimit` is NOT spent on the origin chain: `forwardMessage` packs
    ///      it into `extraArgs` and ships it as data. So an unusably small limit
    ///      costs the sender a fee, returns a txId, and only fails one
    ///      transaction later on the destination -- the origin gets no signal at
    ///      all. There is no floor check on the send path.
    function test_gas_originAcceptsAnUnusableLimitAndStillChargesTheFee() public {
        uint256 balanceBefore = address(origin.controller).balance;

        bytes32 txId = _forwardViaProposal(origin, destination, 1, _cancelPayload(destination));

        assertTrue(txId != bytes32(0), "the send must succeed and return a txId");
        assertEq(balanceBefore - address(origin.controller).balance, FEE, "the doomed send is still charged in full");
        assertEq(origin.router.sentAt(0).gasLimit, 1, "the requested limit must be carried verbatim");
    }
}
