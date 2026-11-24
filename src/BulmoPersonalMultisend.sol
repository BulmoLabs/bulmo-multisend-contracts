// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MultisendCore} from "./MultisendCore.sol";

/// @title Bulmo Personal Multisend
/// @notice Multisend contract without fees, for one owner and a limited number of operators.
/// @dev Deployed as a clone by BulmoMultisendFactory.
contract BulmoPersonalMultisend is MultisendCore, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";
    /// @notice Maximum number of operators.
    uint256 public constant MAX_OPERATORS = 5;

    address public owner;
    address public pendingOwner;
    address public factory;

    /// @notice Whether an address may send through this contract.
    mapping(address => bool) public isOperator;
    /// @notice Number of operators.
    uint256 public operatorCount;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorSet(address indexed operator, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error NotOwner(address caller);
    error NotAllowed(address caller);
    error NotPendingOwner(address caller);
    error ZeroAddress();
    error TooManyOperators(uint256 max);
    error OperatorUnchanged(address operator, bool allowed);
    error RescueFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlySender() {
        if (msg.sender != owner && !isOperator[msg.sender]) revert NotAllowed(msg.sender);
        _;
    }

    /// @dev Locks the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Sets the owner. Called by the factory when the clone is created.
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        factory = msg.sender;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /// @notice Sends native coin to each recipient. `msg.value` must equal the total.
    /// @param recipients Addresses to pay.
    /// @param amounts Amount for each recipient, in wei.
    /// @return total Sum of `amounts`.
    function sendNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
        onlySender
        returns (uint256 total)
    {
        total = _validateAndSum(recipients, amounts);
        if (msg.value != total) revert IncorrectValue(total, msg.value);
        _payNative(recipients, amounts);
        emit NativeMultisent(msg.sender, recipients.length, total, 0);
    }

    /// @notice Sends an ERC-20 token from the caller to each recipient.
    /// @dev Requires an allowance for the total. Does not accept native coin.
    /// @param token Token to send.
    /// @param recipients Addresses to pay.
    /// @param amounts Amount for each recipient, in token units.
    /// @return total Sum of `amounts`.
    function sendToken(IERC20 token, address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
        onlySender
        returns (uint256 total)
    {
        if (msg.value != 0) revert IncorrectValue(0, msg.value);
        total = _validateAndSum(recipients, amounts);
        _payToken(token, msg.sender, recipients, amounts);
        emit TokenMultisent(msg.sender, address(token), recipients.length, total, 0);
    }

    /// @notice Adds or removes an operator.
    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (isOperator[operator] == allowed) revert OperatorUnchanged(operator, allowed);
        if (allowed) {
            if (operatorCount == MAX_OPERATORS) revert TooManyOperators(MAX_OPERATORS);
            operatorCount++;
        } else {
            operatorCount--;
        }
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Starts an ownership transfer. Pass the zero address to cancel it.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accepts a pending ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner(msg.sender);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Withdraws tokens or native coin held by the contract.
    /// @param token Token address, or the zero address for native coin.
    /// @param to Recipient.
    function rescue(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert RescueFailed();
        } else {
            amount = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
