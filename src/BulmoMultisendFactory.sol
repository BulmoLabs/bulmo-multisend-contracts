// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BulmoPersonalMultisend} from "./BulmoPersonalMultisend.sol";
import {UsdPricing} from "./UsdPricing.sol";

/// @title Bulmo Multisend Factory
/// @notice Creates Personal Multisend contracts for a one-time price.
/// @dev Each contract is an EIP-1167 clone. The price is set in USD and paid in native coin.
/// Excess native coin is refunded.
contract BulmoMultisendFactory is UsdPricing, Ownable2Step, ReentrancyGuard {
    string public constant VERSION = "1.0.0";

    /// @notice Implementation used by all clones.
    address public immutable implementation;

    /// @notice Price of a Personal Multisend, in USD (8 decimals).
    uint256 public priceUsd;
    /// @notice Maximum `priceUsd`. Can only be lowered.
    uint256 public maxPriceUsd;
    /// @notice Receives the payments.
    address public treasury;

    /// @notice Whether an address was created by this factory.
    mapping(address => bool) public isPersonalMultisend;
    mapping(address => address[]) private _createdBy;
    /// @notice Number of contracts created.
    uint256 public totalCreated;

    event PersonalMultisendCreated(address indexed buyer, address indexed multisend, bytes32 salt, uint256 pricePaid);
    event PriceUsdUpdated(uint256 previousPriceUsd, uint256 newPriceUsd);
    event MaxPriceUsdLowered(uint256 previousMaxPriceUsd, uint256 newMaxPriceUsd);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event Swept(address indexed to, uint256 amount);

    error InsufficientValue(uint256 required, uint256 sent);
    error RefundFailed();
    error PaymentTransferFailed(address treasury);
    error InvalidTreasury();
    error PriceAboveMax(uint256 priceUsd, uint256 maxPriceUsd);
    error MaxPriceCanOnlyDecrease(uint256 currentMaxPriceUsd, uint256 requested);
    error ZeroAddress();
    error NothingToSweep();
    error SweepFailed();
    error RenounceDisabled();

    /// @param initialOwner Contract owner and initial treasury.
    /// @param initialMaxPriceUsd Maximum price, in USD (8 decimals).
    /// @param initialPriceUsd Initial price, in USD (8 decimals).
    /// @param initialMaxNativeCharge Maximum native amount of a single charge, in wei.
    constructor(
        address initialOwner,
        uint256 initialMaxPriceUsd,
        uint256 initialPriceUsd,
        uint256 initialMaxNativeCharge
    ) Ownable(initialOwner) UsdPricing(initialMaxNativeCharge) {
        if (initialPriceUsd > initialMaxPriceUsd) {
            revert PriceAboveMax(initialPriceUsd, initialMaxPriceUsd);
        }
        maxPriceUsd = initialMaxPriceUsd;
        priceUsd = initialPriceUsd;
        implementation = address(new BulmoPersonalMultisend());
        treasury = initialOwner;
        emit PriceUsdUpdated(0, initialPriceUsd);
        emit TreasuryUpdated(address(0), initialOwner);
    }

    /// @notice Creates a Personal Multisend owned by the caller.
    /// @dev `msg.value` must cover `currentPrice()`. Any excess is refunded.
    /// @param salt Determines the clone address together with the caller.
    function createPersonalMultisend(bytes32 salt) external payable nonReentrant returns (address multisend) {
        uint256 charge = currentPrice();
        if (msg.value < charge) revert InsufficientValue(charge, msg.value);

        multisend = Clones.cloneDeterministic(implementation, _salt(msg.sender, salt));

        isPersonalMultisend[multisend] = true;
        _createdBy[msg.sender].push(multisend);
        unchecked {
            ++totalCreated;
        }
        emit PersonalMultisendCreated(msg.sender, multisend, salt, charge);

        BulmoPersonalMultisend(multisend).initialize(msg.sender);
        if (charge != 0 && !_sendValue(treasury, charge)) revert PaymentTransferFailed(treasury);
        _refund(msg.sender, msg.value - charge);
    }

    /// @notice Current price in wei.
    function currentPrice() public view returns (uint256) {
        return usdToNative(priceUsd);
    }

    /// @notice Current price and the native/USD price it is based on.
    /// @return priceNative Price in wei.
    /// @return usd Price in USD (8 decimals).
    /// @return price Native/USD price (8 decimals). Zero if there is no charge.
    /// @return updatedAt Time the price was updated. Zero if there is no charge.
    function quotePrice() external view returns (uint256 priceNative, uint256 usd, uint256 price, uint256 updatedAt) {
        usd = priceUsd;
        if (usd == 0) return (0, 0, 0, 0);
        (price, updatedAt) = nativeUsdPrice();
        priceNative = usdToNative(usd);
    }

    /// @notice Address of the clone created by `buyer` with `salt`.
    function predictAddress(address buyer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(buyer, salt));
    }

    /// @notice Contracts created by `buyer`. Ownership may have changed since.
    function createdBy(address buyer) external view returns (address[] memory) {
        return _createdBy[buyer];
    }

    /// @notice Sets the price, in USD (8 decimals).
    function setPriceUsd(uint256 newPriceUsd) external onlyOwner {
        if (newPriceUsd > maxPriceUsd) revert PriceAboveMax(newPriceUsd, maxPriceUsd);
        emit PriceUsdUpdated(priceUsd, newPriceUsd);
        priceUsd = newPriceUsd;
    }

    /// @notice Lowers `maxPriceUsd`. A price above the new maximum is reduced to it.
    function lowerMaxPriceUsd(uint256 newMaxPriceUsd) external onlyOwner {
        uint256 current = maxPriceUsd;
        if (newMaxPriceUsd > current) revert MaxPriceCanOnlyDecrease(current, newMaxPriceUsd);
        maxPriceUsd = newMaxPriceUsd;
        emit MaxPriceUsdLowered(current, newMaxPriceUsd);
        if (priceUsd > newMaxPriceUsd) {
            emit PriceUsdUpdated(priceUsd, newMaxPriceUsd);
            priceUsd = newMaxPriceUsd;
        }
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

    /// @notice Sets the address that receives payments.
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

    /// @notice Disabled.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _salt(address buyer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(buyer, salt));
    }

    function _refund(address to, uint256 amount) private {
        if (amount != 0 && !_sendValue(to, amount)) revert RefundFailed();
    }

    /// @dev Native transfer that does not copy return data.
    function _sendValue(address to, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
    }
}
