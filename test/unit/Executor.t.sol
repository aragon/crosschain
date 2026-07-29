// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import { Executor } from "@src/Executor.sol";
import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { CounterTarget } from "@mocks/CounterTarget.sol";

/// @title ExecutorTest
/// @notice Tests the owner-gated `Executor`. The commons `Executor` it extends
///         is permissionless by design -- the `onlyOwner` gate IS this
///         contract's entire reason to exist, so it is what gets pinned here,
///         together with the value-forwarding behaviour the spec documents.
contract ExecutorTest is Test {
    Executor internal executor;
    CounterTarget internal counter;

    address internal owner;
    address internal stranger;

    function setUp() public {
        owner = makeAddr("owner");
        stranger = makeAddr("stranger");

        vm.prank(owner);
        executor = new Executor();

        counter = new CounterTarget();
    }

    function _incrementAction() internal view returns (Action[] memory actions) {
        actions = new Action[](1);
        actions[0] = Action({ to: address(counter), value: 0, data: abi.encodeCall(CounterTarget.increment, ()) });
    }

    // -------------------------------------------------------------------------
    // The `onlyOwner` gate.
    // -------------------------------------------------------------------------

    function test_deployerIsInitialOwner() public view {
        assertEq(executor.owner(), owner);
    }

    function test_revertsWhenNonOwnerExecutes() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(stranger);
        executor.execute(bytes32(0), _incrementAction(), 0);

        assertEq(counter.count(), 0, "the gated action must not have run");
    }

    function test_ownerCanExecute() public {
        vm.prank(owner);
        executor.execute(bytes32(0), _incrementAction(), 0);

        assertEq(counter.count(), 1);
    }

    /// @dev The setup contract's flow: deploy, then hand ownership to the
    ///      plugin. After the transfer the old owner must be locked out.
    function test_transferOwnershipHandsExclusiveControlToNewOwner() public {
        address plugin = makeAddr("plugin");

        vm.prank(owner);
        executor.transferOwnership(plugin);
        assertEq(executor.owner(), plugin);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(owner);
        executor.execute(bytes32(0), _incrementAction(), 0);

        vm.prank(plugin);
        executor.execute(bytes32(0), _incrementAction(), 0);
        assertEq(counter.count(), 1);
    }

    // -------------------------------------------------------------------------
    // Native funds: `receive()` + value-bearing actions.
    // -------------------------------------------------------------------------

    function test_acceptsNativePreFunding() public {
        vm.deal(stranger, 1 ether);

        vm.prank(stranger);
        (bool ok,) = address(executor).call{ value: 1 ether }("");

        assertTrue(ok, "top-ups must be accepted from anyone");
        assertEq(address(executor).balance, 1 ether);
    }

    /// @dev The spec's design: value-bearing actions are paid from the
    ///      executor's OWN balance, so a pre-funded executor can forward value
    ///      even though the execute call itself carries none.
    function test_valueBearingActionIsPaidFromExecutorBalance() public {
        address payable recipient = payable(makeAddr("recipient"));
        vm.deal(address(executor), 1 ether);

        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: recipient, value: 1 ether, data: "" });

        vm.prank(owner);
        executor.execute(bytes32(0), actions, 0);

        assertEq(recipient.balance, 1 ether);
        assertEq(address(executor).balance, 0);
    }

    /// @dev The spec's recovery loop, executor half: underfunded -> the whole
    ///      batch reverts (allowFailureMap 0 tolerates nothing) -> fund ->
    ///      the same batch succeeds.
    function test_underfundedValueActionRevertsThenSucceedsOnceFunded() public {
        address payable recipient = payable(makeAddr("recipient"));

        Action[] memory actions = new Action[](1);
        actions[0] = Action({ to: recipient, value: 1 ether, data: "" });

        vm.expectRevert();
        vm.prank(owner);
        executor.execute(bytes32(0), actions, 0);
        assertEq(recipient.balance, 0);

        vm.deal(address(executor), 1 ether);

        vm.prank(owner);
        executor.execute(bytes32(0), actions, 0);
        assertEq(recipient.balance, 1 ether);
    }
}
