// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.17;

/// @notice A token that burns a fixed percentage of every transfer, so the
///         recipient receives less than the amount the caller asked for.
/// @dev The transfer still SUCCEEDS -- nothing in the execution path can tell
///      that the delivered amount differs from the encoded one. Used to pin
///      that this is a payload-authoring concern, not something the messaging
///      layer detects or compensates for.
/// @dev DO NOT USE IN PRODUCTION! Test-only.
contract FeeOnTransferERC20 {
    string public constant NAME = "FeeOnTransfer";
    string public constant SYMBOL = "FOT";
    uint8 public constant DECIMALS = 18;

    /// @notice Percent of every transfer that is burned.
    uint256 public constant FEE_BPS = 1000; // 10%

    mapping(address => uint256) public balanceOf;

    function setBalance(address _who, uint256 _amount) external {
        balanceOf[_who] = _amount;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        // solhint-disable-next-line custom-errors, reason-string
        require(balanceOf[msg.sender] >= _amount, "FeeOnTransferERC20: insufficient");

        uint256 fee = (_amount * FEE_BPS) / 10_000;

        balanceOf[msg.sender] -= _amount;
        balanceOf[_to] += _amount - fee;

        return true;
    }
}
