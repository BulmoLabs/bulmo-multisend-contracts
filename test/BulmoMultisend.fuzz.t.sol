// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BulmoMultisend} from "../src/BulmoMultisend.sol";
import {MultisendCore} from "../src/MultisendCore.sol";
import {UsdPricing} from "../src/UsdPricing.sol";
import {MockToken} from "./mocks/Tokens.sol";
import {MockAggregator} from "./mocks/MockFeeds.sol";

/// Random lists, amounts, USD fees, coin prices and overpayments: every recipient gets exactly their amount,
/// the contract keeps exactly the converted fee, and the sender gets every extra wei back.
contract BulmoMultisendFuzzTest is Test {
    BulmoMultisend ms;
    MockToken token;
    MockAggregator feed;
    address owner = makeAddr("owner");
    address sender = makeAddr("sender");
    uint256 constant MAX_FEE_USD = 100e8;
    uint256 constant MIN_PRICE = 1e6; // $0.01
    uint256 constant MAX_PRICE = 1e14; // $1,000,000

    function _caps() internal pure returns (uint32[] memory m) {
        m = new uint32[](4);
        (m[0], m[1], m[2], m[3]) = (5, 20, 50, 500);
    }

    function _flat(uint256 feeUsd) internal {
        uint256[] memory f = new uint256[](4);
        (f[0], f[1], f[2], f[3]) = (feeUsd, feeUsd, feeUsd, feeUsd);
        vm.prank(owner);
        ms.setTiers(_caps(), f);
    }

    function _price(uint256 price) internal {
        feed.set(int256(price), block.timestamp);
    }

    function _native(uint256 usd, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(usd, 1e18, price, Math.Rounding.Ceil);
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        // Native cap out of the way here; it has its own fuzz test below.
        ms = new BulmoMultisend(owner, MAX_FEE_USD, type(uint256).max, _caps(), new uint256[](4));
        token = new MockToken("Token", "TKN", 18);
        feed = new MockAggregator(8, 2000e8);
        vm.prank(owner);
        ms.setPriceSource(address(feed), address(0), 1 hours);
    }

    /// Builds n distinct recipients (never zero, never a precompile or this contract) with amounts in [1, maxEach].
    function _list(uint256 n, uint256 seed, uint256 maxEach)
        internal
        pure
        returns (address[] memory r, uint256[] memory a, uint256 total)
    {
        r = new address[](n);
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) | (1 << 159))); // high bit: far from precompiles
            a[i] = bound(uint256(keccak256(abi.encode(seed, i, "amt"))), 1, maxEach);
            total += a[i];
        }
    }

    // ---------------------------------------------------------------- payouts + refunds

    function testFuzz_sendNative_exactPayoutsAndRefund(
        uint8 rawN,
        uint256 seed,
        uint64 rawFeeUsd,
        uint64 rawPrice,
        uint96 extra
    ) public {
        uint256 n = bound(rawN, 1, 120);
        uint256 feeUsd = bound(rawFeeUsd, 0, MAX_FEE_USD);
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _flat(feeUsd);
        _price(price);
        uint256 fee = _native(feeUsd, price);
        assertEq(ms.feeFor(n), fee, "feeFor matches the conversion");

        (address[] memory r, uint256[] memory a, uint256 total) = _list(n, seed, 1_000 ether);
        uint256 sent = total + fee + extra;
        vm.deal(sender, sent);
        vm.prank(sender);
        uint256 returned = ms.sendNative{value: sent}(r, a);

        assertEq(returned, total);
        for (uint256 i; i < n; ++i) {
            assertEq(r[i].balance, a[i]);
        }
        assertEq(owner.balance, fee, "fee went to the treasury (owner)");
        assertEq(address(ms).balance, 0, "contract holds nothing");
        assertEq(sender.balance, extra, "every extra wei refunded");
    }

    function testFuzz_sendToken_exactPayoutsAndRefund(
        uint8 rawN,
        uint256 seed,
        uint64 rawFeeUsd,
        uint64 rawPrice,
        uint96 extra
    ) public {
        uint256 n = bound(rawN, 1, 120);
        uint256 feeUsd = bound(rawFeeUsd, 0, MAX_FEE_USD);
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _flat(feeUsd);
        _price(price);
        uint256 fee = _native(feeUsd, price);

        (address[] memory r, uint256[] memory a, uint256 total) = _list(n, seed, 1e30);
        token.mint(sender, total);
        vm.deal(sender, fee + extra);
        vm.startPrank(sender);
        token.approve(address(ms), total);
        ms.sendToken{value: fee + extra}(token, r, a);
        vm.stopPrank();

        for (uint256 i; i < n; ++i) {
            assertEq(token.balanceOf(r[i]), a[i]);
        }
        assertEq(token.balanceOf(address(ms)), 0, "never holds tokens");
        assertEq(token.balanceOf(sender), 0);
        assertEq(owner.balance, fee);
        assertEq(address(ms).balance, 0);
        assertEq(sender.balance, extra);
    }

    function testFuzz_sendNative_anyShortfallReverts(uint256 seed, uint64 rawFeeUsd, uint64 rawPrice, uint256 sent)
        public
    {
        uint256 feeUsd = bound(rawFeeUsd, 0, MAX_FEE_USD);
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _flat(feeUsd);
        _price(price);
        (address[] memory r, uint256[] memory a, uint256 total) = _list(5, seed, 10 ether);
        uint256 required = total + _native(feeUsd, price);
        sent = bound(sent, 0, required - 1);

        vm.deal(sender, sent);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, required, sent));
        vm.prank(sender);
        ms.sendNative{value: sent}(r, a);
    }

    function testFuzz_sendToken_anyShortfallReverts(uint64 rawFeeUsd, uint64 rawPrice, uint256 sent) public {
        uint256 feeUsd = bound(rawFeeUsd, 1, MAX_FEE_USD);
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _flat(feeUsd);
        _price(price);
        uint256 fee = _native(feeUsd, price);
        sent = bound(sent, 0, fee - 1);
        (address[] memory r, uint256[] memory a,) = _list(3, 1, 10);

        vm.deal(sender, sent);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, fee, sent));
        vm.prank(sender);
        ms.sendToken{value: sent}(token, r, a);
    }

    // ---------------------------------------------------------------- conversion

    /// Rounding always favours neither side by more than 1 wei, and never undercharges.
    function testFuzz_usdToNative_ceilWithinOneWei(uint256 usd, uint64 rawPrice) public {
        usd = bound(usd, 1, 1e18); // up to $10B
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _price(price);
        uint256 n = ms.usdToNative(usd);
        assertGe(n * price, usd * 1e18, "never undercharges");
        assertLt((n - 1) * price, usd * 1e18, "overcharge below 1 wei");
    }

    /// The same price reported with any decimals 8..18 gives the same charge.
    function testFuzz_feedDecimals_scaleExactly(uint8 rawDec, uint64 rawPrice, uint64 rawFeeUsd) public {
        uint8 dec = uint8(bound(rawDec, 8, 18));
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        uint256 feeUsd = bound(rawFeeUsd, 1, MAX_FEE_USD);
        _flat(feeUsd);
        MockAggregator f2 = new MockAggregator(dec, int256(price * 10 ** (dec - 8)));
        vm.prank(owner);
        ms.setPriceSource(address(f2), address(0), 1 hours);
        assertEq(ms.feeFor(1), _native(feeUsd, price));
        (uint256 p,) = ms.nativeUsdPrice();
        assertEq(p, price);
    }

    /// Feeds with fewer than 8 decimals are scaled up exactly.
    function testFuzz_feedDecimals_belowEight(uint8 rawDec, uint64 rawWhole) public {
        uint8 dec = uint8(bound(rawDec, 0, 7));
        uint256 answer = bound(rawWhole, 1, 1e12);
        MockAggregator f2 = new MockAggregator(dec, int256(answer));
        vm.prank(owner);
        ms.setPriceSource(address(f2), address(0), 1 hours);
        (uint256 p,) = ms.nativeUsdPrice();
        assertEq(p, answer * 10 ** (8 - dec));
    }

    function testFuzz_staleness_boundary(uint32 rawMaxAge, uint32 age) public {
        uint32 maxAge = uint32(bound(rawMaxAge, 1, 30 days));
        vm.prank(owner);
        ms.setPriceSource(address(feed), address(0), maxAge);
        _flat(10e8);
        uint256 updatedAt = block.timestamp - bound(age, 0, 60 days);
        feed.set(2000e8, updatedAt);
        if (block.timestamp - updatedAt > maxAge) {
            vm.expectRevert(abi.encodeWithSelector(UsdPricing.StalePrice.selector, updatedAt, maxAge));
            ms.feeFor(1);
        } else {
            assertEq(ms.feeFor(1), 0.005 ether);
        }
    }

    function testFuzz_nativeCap_isHardLimit(uint64 rawPrice, uint256 cap) public {
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _price(price);
        _flat(49e8);
        uint256 fee = _native(49e8, price);
        cap = bound(cap, 0, fee * 2);
        vm.prank(owner);
        ms.lowerMaxNativeCharge(cap);
        if (fee > cap) {
            vm.expectRevert(abi.encodeWithSelector(UsdPricing.NativeChargeAboveCap.selector, fee, cap));
            ms.feeFor(6);
        } else {
            assertEq(ms.feeFor(6), fee);
        }
        // Free sends never depend on the price or the cap.
        _flat(0);
        assertEq(ms.feeFor(6), 0);
    }

    function testFuzz_quote_matchesCharge(uint16 rawCount, uint64 rawPrice) public {
        uint256[] memory f = new uint256[](4);
        (f[0], f[1], f[2], f[3]) = (0, 10e8, 19e8, 49e8);
        vm.prank(owner);
        ms.setTiers(_caps(), f);
        uint256 price = bound(rawPrice, MIN_PRICE, MAX_PRICE);
        _price(price);
        uint256 count = bound(rawCount, 1, 500);
        (uint256 feeNative, uint256 feeUsd, uint256 p,) = ms.quote(count);
        assertEq(feeNative, ms.feeFor(count));
        assertEq(feeUsd, ms.feeUsdFor(count));
        assertEq(p, feeUsd == 0 ? 0 : price);
    }

    // ---------------------------------------------------------------- tiers + caps

    function testFuzz_setTiers_succeedsIffAllWithinCap(uint256 f0, uint256 f1, uint256 f2, uint256 f3) public {
        uint256[] memory f = new uint256[](4);
        (f[0], f[1], f[2], f[3]) = (f0, f1, f2, f3);
        vm.prank(owner);
        bool anyOver;
        uint256 firstOver;
        for (uint256 i; i < 4; ++i) {
            if (f[i] > MAX_FEE_USD) {
                (anyOver, firstOver) = (true, f[i]);
                break;
            }
        }
        if (anyOver) {
            vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.FeeAboveMax.selector, firstOver, MAX_FEE_USD));
            ms.setTiers(_caps(), f);
        } else {
            ms.setTiers(_caps(), f);
            assertEq(ms.feeUsdFor(5), f0);
            assertEq(ms.feeUsdFor(20), f1);
            assertEq(ms.feeUsdFor(50), f2);
            assertEq(ms.feeUsdFor(500), f3);
        }
    }

    /// Random valid tables and list sizes: the fee charged always equals the table's row for that size.
    function testFuzz_feeUsdFor_matchesTable(uint8 rawTiers, uint256 seed, uint16 rawCount) public {
        uint256 n = bound(rawTiers, 1, 5);
        uint32[] memory m = new uint32[](n);
        uint256[] memory f = new uint256[](n);
        uint32 prev;
        for (uint256 i; i < n; ++i) {
            uint32 room = uint32(500 - prev - (n - 1 - i)); // leave space for the remaining tiers
            m[i] = i == n - 1 ? 500 : prev + uint32(bound(uint256(keccak256(abi.encode(seed, i))), 1, room));
            f[i] = bound(uint256(keccak256(abi.encode(seed, i, "fee"))), 0, MAX_FEE_USD);
            prev = m[i];
        }
        vm.prank(owner);
        ms.setTiers(m, f);

        uint256 count = bound(rawCount, 1, 500);
        uint256 expected;
        for (uint256 i; i < n; ++i) {
            if (count <= m[i]) {
                expected = f[i];
                break;
            }
        }
        assertEq(ms.feeUsdFor(count), expected);
        assertLe(ms.feeUsdFor(count), ms.maxFeeUsd());
        assertEq(ms.feeFor(count), _native(expected, 2000e8));
    }

    function testFuzz_lowerMaxFeeUsd_neverIncreasesAndClamps(uint256 first, uint256 second, uint256 feeBefore) public {
        feeBefore = bound(feeBefore, 0, MAX_FEE_USD);
        _flat(feeBefore);
        vm.startPrank(owner);

        first = bound(first, 0, MAX_FEE_USD);
        ms.lowerMaxFeeUsd(first);
        assertEq(ms.maxFeeUsd(), first);
        assertLe(ms.feeUsdFor(500), first);
        assertEq(ms.feeUsdFor(1), feeBefore < first ? feeBefore : first);

        if (second > first) {
            vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.MaxFeeCanOnlyDecrease.selector, first, second));
            ms.lowerMaxFeeUsd(second);
        } else {
            ms.lowerMaxFeeUsd(second);
            assertEq(ms.maxFeeUsd(), second);
        }
        vm.stopPrank();
    }

    function testFuzz_lowerMaxNativeCharge_neverIncreases(uint256 first, uint256 second) public {
        vm.startPrank(owner);
        ms.lowerMaxNativeCharge(first);
        assertEq(ms.maxNativeCharge(), first);
        if (second > first) {
            vm.expectRevert(abi.encodeWithSelector(UsdPricing.MaxNativeChargeCanOnlyDecrease.selector, first, second));
        }
        ms.lowerMaxNativeCharge(second);
        vm.stopPrank();
        assertEq(ms.maxNativeCharge(), second > first ? first : second);
    }

    function testFuzz_onlyOwnerCanAdminister(address caller) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert();
        ms.setTiers(_caps(), new uint256[](4));
        vm.expectRevert();
        ms.lowerMaxFeeUsd(0);
        vm.expectRevert();
        ms.setPriceSource(address(0), address(0), 0);
        vm.expectRevert();
        ms.setManualPrice(1);
        vm.expectRevert();
        ms.lowerMaxNativeCharge(0);
        vm.expectRevert();
        ms.sweep(payable(caller));
        vm.expectRevert();
        ms.setTreasury(caller);
        vm.expectRevert();
        ms.rescueTokens(token, caller);
        vm.stopPrank();
    }
}
