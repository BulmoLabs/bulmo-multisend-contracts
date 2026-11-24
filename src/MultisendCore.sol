// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MultisendCore
/// @notice Batch transfers of native coin and ERC-20 tokens.
/// @dev Reverts the whole batch if any transfer fails.
abstract contract MultisendCore {
    using SafeERC20 for IERC20;

    /// @notice Maximum number of recipients per call.
    uint256 public constant MAX_RECIPIENTS = 500;

    event NativeMultisent(address indexed sender, uint256 recipients, uint256 total, uint256 fee);
    event TokenMultisent(address indexed sender, address indexed token, uint256 recipients, uint256 total, uint256 fee);

    error NoRecipients();
    error TooManyRecipients(uint256 count, uint256 max);
    error LengthMismatch(uint256 recipients, uint256 amounts);
    error ZeroAddressRecipient(uint256 index);
    error ZeroAmount(uint256 index);
    error IncorrectValue(uint256 expected, uint256 sent);
    error NativeTransferFailed(uint256 index, address recipient);
    error InsufficientValue(uint256 required, uint256 sent);
    error RefundFailed();
    error FeeTransferFailed(address treasury);

    /// @dev Validates the recipient list and returns the sum of `amounts`.
    function _validateAndSum(address[] calldata recipients, uint256[] calldata amounts)
        internal
        pure
        returns (uint256 total)
    {
        uint256 count = recipients.length;
        if (count == 0) revert NoRecipients();
        if (count > MAX_RECIPIENTS) revert TooManyRecipients(count, MAX_RECIPIENTS);
        if (count != amounts.length) revert LengthMismatch(count, amounts.length);

        for (uint256 i; i < count; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddressRecipient(i);
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount(i);
            total += amount;
        }
    }

    /// @dev Sends native coin to each recipient. The caller must check `msg.value` first.
    /// Return data is not copied, so a recipient cannot exhaust gas with a large return value.
    function _payNative(address[] calldata recipients, uint256[] calldata amounts) internal {
        uint256 count = recipients.length;
        for (uint256 i; i < count; ++i) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            bool ok;
            assembly ("memory-safe") {
                ok := call(gas(), to, amount, 0, 0, 0, 0)
            }
            if (!ok) revert NativeTransferFailed(i, to);
        }
    }

    /// @dev Returns excess native coin to `to`.
    function _refund(address to, uint256 amount) internal {
        if (amount != 0 && !_sendValue(to, amount)) revert RefundFailed();
    }

    /// @dev Sends the fee to the treasury.
    function _forwardFee(address to, uint256 fee) internal {
        if (fee != 0 && !_sendValue(to, fee)) revert FeeTransferFailed(to);
    }

    /// @dev Native transfer that does not copy return data.
    function _sendValue(address to, uint256 amount) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
    }

    /// @dev Transfers `token` from `from` to each recipient. Requires an allowance for the total.
    function _payToken(IERC20 token, address from, address[] calldata recipients, uint256[] calldata amounts) internal {
        uint256 count = recipients.length;
        for (uint256 i; i < count; ++i) {
            token.safeTransferFrom(from, recipients[i], amounts[i]);
        }
    }
}
