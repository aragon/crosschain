// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A third-party contract that pulls tokens from its caller via
///         `transferFrom`, the way a staking pool, escrow or DEX router does.
/// @dev Lets a test exercise the two-action `approve` + `pull` pattern, which
///      is how most real ERC20 integrations are driven from a cross-chain
///      payload. Exposes both a `SafeERC20` pull and a naive one, because the
///      difference decides whether a token that returns `false` instead of
///      reverting is caught or silently swallowed.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract TokenPuller {
    using SafeERC20 for IERC20;

    uint256 public pulled;

    /// @dev Return-value checked. A `false` return reverts here.
    function pull(address _token, uint256 _amount) external {
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        pulled += _amount;
    }

    /// @dev Typed call whose `bool` return is discarded. Solidity does NOT
    ///      revert on a `false` return -- it only reverts when the returndata
    ///      cannot be decoded -- so this swallows the failure exactly like the
    ///      executor's raw `.call` does.
    function pullUnchecked(address _token, uint256 _amount) external {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        pulled += _amount;
    }
}
