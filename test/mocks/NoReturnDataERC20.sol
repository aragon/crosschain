// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice A USDT-style token whose `transfer` / `approve` return NO data at
///         all, rather than the `bool` the ERC20 interface declares.
/// @dev Included because it is the mirror image of `SilentFailERC20`: a raw
///      low-level `.call` that ignores returndata handles this token fine,
///      whereas a strongly-typed `IERC20.transfer` call would revert on the
///      empty return. It pins which of the two the execution path does.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract NoReturnDataERC20 {
    string public constant NAME = "NoReturn";
    string public constant SYMBOL = "NORET";
    uint8 public constant DECIMALS = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error InsufficientBalance();

    function setBalance(address _who, uint256 _amount) external {
        balanceOf[_who] = _amount;
    }

    /// @dev Reverts when short, but returns nothing on success.
    function transfer(address _to, uint256 _amount) external {
        if (balanceOf[msg.sender] < _amount) revert InsufficientBalance();

        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount;
    }

    function transferFrom(address _from, address _to, uint256 _amount) external {
        if (balanceOf[_from] < _amount || allowance[_from][msg.sender] < _amount) revert InsufficientBalance();

        allowance[_from][msg.sender] -= _amount;
        balanceOf[_from] -= _amount;
        balanceOf[_to] += _amount;
    }

    function approve(address _spender, uint256 _amount) external {
        allowance[msg.sender][_spender] = _amount;
    }
}
