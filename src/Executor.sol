// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Action } from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import { Executor as CommonsExecutor } from "@aragon/osx-commons-contracts/src/executors/Executor.sol";

/// @title Executor
/// @notice An `Executor` whose execution is restricted to a single owner.
/// @dev The commons `Executor` is permissionless by design: anyone can call
///      `execute`. This variant gates it behind `Ownable`, so it can be deployed
///      standalone (not via `delegatecall`) and pointed at by a
///      `CrossChainController` that is set as its owner.
/// @custom:security-contact sirt@aragon.org
contract Executor is CommonsExecutor, Ownable {
    /// @inheritdoc CommonsExecutor
    /// @dev Restricted to the owner; the rest of the behaviour (bounds check,
    ///      failure map, reentrancy guard, `Executed` event) is unchanged.
    function execute(bytes32 _callId, Action[] memory _actions, uint256 _allowFailureMap)
        public
        virtual
        override
        onlyOwner
        returns (bytes[] memory execResults, uint256 failureMap)
    {
        return super.execute(_callId, _actions, _allowFailureMap);
    }

    // If this is topped up, even if `Action[]` contains value > 0,
    // it can execute actions and forward value.
    receive() external payable { }
}
