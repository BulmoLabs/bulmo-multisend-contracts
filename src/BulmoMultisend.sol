// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MultisendCore} from "./MultisendCore.sol";
import {UsdPricing} from "./UsdPricing.sol";

/// @title Bulmo Multisend
/// @notice Sends native coin or an ERC-20 token to many wallets in one transaction.
/// @dev The fee depends on the number of recipients. It is set in USD and paid in native coin.
/// Excess native coin is refunded. Tokens move directly from the sender to each recipient.
contract BulmoMultisend is MultisendCore, UsdPricing, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";

    /// @notice Maximum number of fee tiers.
    uint256 public constant MAX_TIERS = 5;

    /// @dev Calls with up to `maxRecipients` recipients pay `feeUsd` (8 decimals).
    struct Tier {
        uint32 maxRecipients;
        uint224 feeUsd;
    }

    /// @dev Sorted by `maxRecipients`. The last tier covers MAX_RECIPIENTS.
    Tier[] private _tiers;

    /// @notice Maximum fee of any tier, in USD (8 decimals). Can only be lowered.
    uint256 public maxFeeUsd;

    /// @notice Receives the fees.
    address public treasury;

    event TiersUpdated(uint32[] maxRecipients, uint256[] feesUsd);
    event MaxFeeUsdLowered(uint256 previousMaxFeeUsd, uint256 newMaxFeeUsd);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event Swept(address indexed to, uint256 amount);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    error FeeAboveMax(uint256 feeUsd, uint256 maxFeeUsd);
    error InvalidTiers();
    error MaxFeeCanOnlyDecrease(uint256 currentMaxFeeUsd, uint256 requested);
    error ZeroAddress();
    error InvalidTreasury();
    error NothingToSweep();
    error SweepFailed();
    error RenounceDisabled();

    /// @param initialOwner Contract owner and initial treasury.
    /// @param initialMaxFeeUsd Maximum fee of any tier, in USD (8 decimals).
    /// @param initialMaxNativeCharge Maximum native amount of a single charge, in wei.
    /// @param tierMaxRecipients Upper bound of each tier, in ascending order.
    /// @param tierFeesUsd Fee of each tier, in USD (8 decimals).
    constructor(
        address initialOwner,
        uint256 initialMaxFeeUsd,
        uint256 initialMaxNativeCharge,
        uint32[] memory tierMaxRecipients,
        uint256[] memory tierFeesUsd
    ) Ownable(initialOwner) UsdPricing(initialMaxNativeCharge) {
        if (initialMaxFeeUsd > type(uint224).max) {
            revert FeeAboveMax(initialMaxFeeUsd, type(uint224).max);
        }
        maxFeeUsd = initialMaxFeeUsd;
        _setTiers(tierMaxRecipients, tierFeesUsd);
        treasury = initialOwner;
        emit TreasuryUpdated(address(0), initialOwner);
    }

    /// @notice Sends native coin to each recipient.
    /// @dev `msg.value` must cover the total and the fee. Any excess is refunded.
    /// @param recipients Addresses to pay.
    /// @param amounts Amount for each recipient, in wei.
    /// @return total Sum of `amounts`.
    function sendNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
        returns (uint256 total)
    {
        total = _validateAndSum(recipients, amounts);
        uint256 fee = feeFor(recipients.length);
        uint256 required = total + fee;
        if (msg.value < required) revert InsufficientValue(required, msg.value);
        _payNative(recipients, amounts);
        emit NativeMultisent(msg.sender, recipients.length, total, fee);
        _forwardFee(treasury, fee);
        _refund(msg.sender, msg.value - required);
    }

    /// @notice Sends an ERC-20 token to each recipient.
    /// @dev Requires an allowance for the total. `msg.value` must cover the fee. Any excess is refunded.
    /// @param token Token to send.
    /// @param recipients Addresses to pay.
    /// @param amounts Amount for each recipient, in token units.
    /// @return total Sum of `amounts`.
    function sendToken(IERC20 token, address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
        returns (uint256 total)
    {
        total = _validateAndSum(recipients, amounts);
        uint256 fee = feeFor(recipients.length);
        if (msg.value < fee) revert InsufficientValue(fee, msg.value);
        _payToken(token, msg.sender, recipients, amounts);
        emit TokenMultisent(msg.sender, address(token), recipients.length, total, fee);
        _forwardFee(treasury, fee);
        _refund(msg.sender, msg.value - fee);
    }

    /// @notice Fee in USD (8 decimals) for `recipientCount` recipients.
    function feeUsdFor(uint256 recipientCount) public view returns (uint256) {
        uint256 n = _tiers.length;
        for (uint256 i; i < n; ++i) {
            if (recipientCount <= _tiers[i].maxRecipients) return _tiers[i].feeUsd;
        }
        revert TooManyRecipients(recipientCount, MAX_RECIPIENTS);
    }

    /// @notice Fee in wei for `recipientCount` recipients at the current price.
    function feeFor(uint256 recipientCount) public view returns (uint256) {
        return usdToNative(feeUsdFor(recipientCount));
    }

    /// @notice Fee for `recipientCount` recipients and the price it is based on.
    /// @return feeNative Fee in wei.
    /// @return feeUsd Fee in USD (8 decimals).
    /// @return price Native/USD price (8 decimals). Zero if there is no fee.
    /// @return updatedAt Time the price was updated. Zero if there is no fee.
    function quote(uint256 recipientCount)
        external
        view
        returns (uint256 feeNative, uint256 feeUsd, uint256 price, uint256 updatedAt)
    {
        feeUsd = feeUsdFor(recipientCount);
        if (feeUsd == 0) return (0, 0, 0, 0);
        (price, updatedAt) = nativeUsdPrice();
        feeNative = usdToNative(feeUsd);
    }

    /// @notice All fee tiers.
    function tiers() external view returns (uint32[] memory maxRecipients, uint256[] memory feesUsd) {
        uint256 n = _tiers.length;
        maxRecipients = new uint32[](n);
        feesUsd = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            maxRecipients[i] = _tiers[i].maxRecipients;
            feesUsd[i] = _tiers[i].feeUsd;
        }
    }

    /// @notice Replaces the fee tiers.
    function setTiers(uint32[] calldata maxRecipients, uint256[] calldata feesUsd) external onlyOwner {
        _setTiers(maxRecipients, feesUsd);
    }

    /// @notice Lowers `maxFeeUsd`. Tiers above the new maximum are reduced to it.
    function lowerMaxFeeUsd(uint256 newMaxFeeUsd) external onlyOwner {
        uint256 current = maxFeeUsd;
        if (newMaxFeeUsd > current) revert MaxFeeCanOnlyDecrease(current, newMaxFeeUsd);
        maxFeeUsd = newMaxFeeUsd;
        emit MaxFeeUsdLowered(current, newMaxFeeUsd);

        uint256 n = _tiers.length;
        bool clamped = false;
        for (uint256 i; i < n; ++i) {
            if (_tiers[i].feeUsd > newMaxFeeUsd) {
                _tiers[i].feeUsd = uint224(newMaxFeeUsd);
                clamped = true;
            }
        }
        if (clamped) _emitTiers();
    }

    /// @notice Sets the Chainlink feeds. Pass zero values to use the manual price.
    /// @param feed Native/USD feed.
    /// @param sequencer L2 sequencer uptime feed, or the zero address.
    /// @param maxAge Maximum age of a feed answer, in seconds.
    function setPriceSource(address feed, address sequencer, uint32 maxAge) external onlyOwner {
        _setPriceSource(feed, sequencer, maxAge);
    }

    /// @notice Sets the native/USD price (8 decimals) used when there is no feed.
    function setManualPrice(uint256 price) external onlyOwner {
        _setManualPrice(price);
    }

    /// @notice Lowers `maxNativeCharge`.
    function lowerMaxNativeCharge(uint256 newCap) external onlyOwner {
        _lowerMaxNativeCharge(newCap);
    }

    /// @notice Sets the address that receives fees.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0) || newTreasury == address(this)) revert InvalidTreasury();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Withdraws native coin that was forced into the contract.
    function sweep(address payable to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        if (!_sendValue(to, amount)) revert SweepFailed();
        emit Swept(to, amount);
    }

    /// @notice Withdraws tokens sent to the contract by mistake.
    function rescueTokens(IERC20 token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        emit TokensRescued(address(token), to, amount);
    }

    /// @notice Disabled.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _setTiers(uint32[] memory maxRecipients, uint256[] memory feesUsd) private {
        uint256 n = maxRecipients.length;
        if (n == 0 || n > MAX_TIERS || n != feesUsd.length) revert InvalidTiers();
        if (maxRecipients[n - 1] != MAX_RECIPIENTS) revert InvalidTiers();

        delete _tiers;
        uint256 cap = maxFeeUsd;
        uint32 previous;
        for (uint256 i; i < n; ++i) {
            if (maxRecipients[i] <= previous) revert InvalidTiers();
            if (feesUsd[i] > cap) revert FeeAboveMax(feesUsd[i], cap);
            previous = maxRecipients[i];
            // feesUsd[i] <= maxFeeUsd, which fits in uint224
            _tiers.push(Tier({maxRecipients: maxRecipients[i], feeUsd: uint224(feesUsd[i])}));
        }
        emit TiersUpdated(maxRecipients, feesUsd);
    }

    function _emitTiers() private {
        uint256 n = _tiers.length;
        uint32[] memory m = new uint32[](n);
        uint256[] memory f = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = _tiers[i].maxRecipients;
            f[i] = _tiers[i].feeUsd;
        }
        emit TiersUpdated(m, f);
    }
}
