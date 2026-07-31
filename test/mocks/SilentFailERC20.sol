// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice A token that returns `false` from `transfer` instead of reverting
///         when the sender is short.
/// @dev Legal under EIP-20 -- the spec says `transfer` "SHOULD throw", not
///      MUST, and several long-lived tokens return `false` instead. It is the
///      exact shape `SafeERC20` exists to defend against, and the reason a raw
///      `.call` that only checks the call's `success` flag is not enough to
///      know a transfer happened.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract SilentFailERC20 {
    string public constant NAME = "SilentFail";
    string public constant SYMBOL = "SFAIL";
    uint8 public constant DECIMALS = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setBalance(address _who, uint256 _amount) external {
        balanceOf[_who] = _amount;
    }

    /// @dev Returns `false` rather than reverting when short.
    function transfer(address _to, uint256 _amount) external returns (bool) {
        if (balanceOf[msg.sender] < _amount) return false;

        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount;

        return true;
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        allowance[msg.sender][_spender] = _amount;
        return true;
    }

    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        if (balanceOf[_from] < _amount || allowance[_from][msg.sender] < _amount) return false;

        allowance[_from][msg.sender] -= _amount;
        balanceOf[_from] -= _amount;
        balanceOf[_to] += _amount;

        return true;
    }
}
