// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Subset of the Chainlink AggregatorV3 interface.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title UsdPricing
/// @notice Converts USD amounts (8 decimals) to the native coin of the chain.
/// @dev Reads a Chainlink native/USD feed, or a price set by the owner on chains without one.
/// Reverts with {PriceUnavailable} until a price source is configured. Zero amounts never read the price.
abstract contract UsdPricing {
    /// @notice Decimals of all USD amounts.
    uint8 public constant USD_DECIMALS = 8;
    /// @notice Time to wait after an L2 sequencer restart before trusting the feed.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @notice Chainlink native/USD feed, or the zero address if `manualPrice` is used.
    address public priceFeed;
    /// @notice Chainlink L2 sequencer uptime feed, or the zero address if not used.
    address public sequencerFeed;
    /// @notice Maximum age of a feed answer, in seconds.
    uint32 public maxPriceAge;
    /// @notice Decimals of `priceFeed`.
    uint8 public priceFeedDecimals;
    /// @notice Native/USD price (8 decimals) used when no feed is set.
    uint256 public manualPrice;
    /// @notice Timestamp of the last `manualPrice` update.
    uint256 public manualPriceUpdatedAt;
    /// @notice Maximum native amount of a single charge, in wei. Can only be lowered.
    uint256 public maxNativeCharge;

    event PriceSourceUpdated(address indexed priceFeed, address indexed sequencerFeed, uint32 maxPriceAge);
    event ManualPriceUpdated(uint256 previousPrice, uint256 newPrice);
    event MaxNativeChargeLowered(uint256 previousCap, uint256 newCap);

    error PriceUnavailable();
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error SequencerDown();
    error SequencerGracePeriod(uint256 upSince);
    error NativeChargeAboveCap(uint256 charge, uint256 cap);
    error MaxNativeChargeCanOnlyDecrease(uint256 currentCap, uint256 requested);
    error InvalidPriceSource();

    constructor(uint256 initialMaxNativeCharge) {
        maxNativeCharge = initialMaxNativeCharge;
    }

    /// @notice Current native/USD price (8 decimals) and the time it was updated.
    function nativeUsdPrice() public view returns (uint256 price, uint256 updatedAt) {
        address feed = priceFeed;
        if (feed == address(0)) {
            price = manualPrice;
            if (price == 0) revert PriceUnavailable();
            return (price, manualPriceUpdatedAt);
        }

        address seq = sequencerFeed;
        if (seq != address(0)) {
            (, int256 status, uint256 upSince,,) = IAggregatorV3(seq).latestRoundData();
            if (status != 0) revert SequencerDown(); // 0: up, 1: down
            if (upSince == 0 || block.timestamp - upSince <= SEQUENCER_GRACE_PERIOD) {
                revert SequencerGracePeriod(upSince);
            }
        }

        (, int256 answer,, uint256 updated,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0 || updated == 0 || updated > block.timestamp) revert PriceUnavailable();
        if (block.timestamp - updated > maxPriceAge) revert StalePrice(updated, maxPriceAge);

        uint8 dec = priceFeedDecimals;
        price = uint256(answer);
        if (dec > USD_DECIMALS) price /= 10 ** (dec - USD_DECIMALS);
        else if (dec < USD_DECIMALS) price *= 10 ** (USD_DECIMALS - dec);
        if (price == 0) revert PriceUnavailable();
        updatedAt = updated;
    }

    /// @notice Converts a USD amount (8 decimals) to wei, rounded up.
    /// @dev Reverts if the result exceeds `maxNativeCharge`.
    function usdToNative(uint256 usdAmount) public view returns (uint256 nativeAmount) {
        if (usdAmount == 0) return 0;
        (uint256 price,) = nativeUsdPrice();
        nativeAmount = Math.mulDiv(usdAmount, 1e18, price, Math.Rounding.Ceil);
        if (nativeAmount > maxNativeCharge) revert NativeChargeAboveCap(nativeAmount, maxNativeCharge);
    }

    function _setPriceSource(address feed, address sequencer, uint32 maxAge) internal {
        uint8 dec;
        if (feed != address(0)) {
            if (maxAge == 0) revert InvalidPriceSource();
            dec = IAggregatorV3(feed).decimals();
            if (dec > 18) revert InvalidPriceSource();
        } else if (sequencer != address(0) || maxAge != 0) {
            revert InvalidPriceSource();
        }
        priceFeed = feed;
        sequencerFeed = sequencer;
        maxPriceAge = maxAge;
        priceFeedDecimals = dec;
        emit PriceSourceUpdated(feed, sequencer, maxAge);
    }

    function _setManualPrice(uint256 price) internal {
        emit ManualPriceUpdated(manualPrice, price);
        manualPrice = price;
        manualPriceUpdatedAt = block.timestamp;
    }

    function _lowerMaxNativeCharge(uint256 newCap) internal {
        uint256 current = maxNativeCharge;
        if (newCap > current) revert MaxNativeChargeCanOnlyDecrease(current, newCap);
        maxNativeCharge = newCap;
        emit MaxNativeChargeLowered(current, newCap);
    }
}
