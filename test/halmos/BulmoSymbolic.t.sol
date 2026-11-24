// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BulmoMultisend} from "../../src/BulmoMultisend.sol";
import {BulmoMultisendFactory} from "../../src/BulmoMultisendFactory.sol";
import {BulmoPersonalMultisend} from "../../src/BulmoPersonalMultisend.sol";

/// Symbolic proofs for Halmos: `halmos --match-contract BulmoSymbolic`.
///
/// Every `check_` function's arguments are symbolic: Halmos proves the asserts hold for *every* possible
/// value (all 2^256 of them), not for random samples. A counterexample is printed if one exists.
/// The price comes from the manual price, so the coin price is symbolic too.
contract BulmoSymbolic is Test {
    BulmoMultisend internal ms;
    BulmoMultisendFactory internal factory;
    address internal owner = address(0xB0B);
    address internal treasury = address(0x7EA5);
    address internal r1 = address(0x1001);
    address internal r2 = address(0x1002);

    uint256 internal constant MAX_FEE_USD = 100e8;
    uint256 internal constant NATIVE_CAP = 10 ether;

    function setUp() public {
        uint32[] memory m = new uint32[](4);
        uint256[] memory f = new uint256[](4);
        (m[0], m[1], m[2], m[3]) = (5, 20, 50, 500);
        (f[0], f[1], f[2], f[3]) = (0, 10e8, 19e8, 49e8);
        ms = new BulmoMultisend(owner, MAX_FEE_USD, NATIVE_CAP, m, f);
        factory = new BulmoMultisendFactory(owner, 100e8, 49e8, NATIVE_CAP);
        vm.startPrank(owner);
        ms.setTreasury(treasury);
        factory.setTreasury(treasury);
        vm.stopPrank();
    }

    /// S1: USD to coin conversion always rounds up (never undercharges by even 1 wei),
    /// is never more than 1 wei above the exact value, and never exceeds the coin cap.
    function check_usdToNative_roundsUpAndIsCapped(uint256 usd, uint256 price) public {
        vm.assume(price > 0 && price < 1e20 && usd > 0 && usd <= MAX_FEE_USD);
        vm.prank(owner);
        ms.setManualPrice(price);
        try ms.usdToNative(usd) returns (uint256 wei_) {
            assert(wei_ * price >= usd * 1e18); // covers the dollar amount
            assert((wei_ - 1) * price < usd * 1e18); // by at most 1 wei
            assert(wei_ <= ms.maxNativeCharge());
        } catch {
            // only allowed when the exact charge is above the cap
            assert(usd * 1e18 > ms.maxNativeCharge() * price);
        }
    }

    /// S2: whatever tiers the owner sets, no fee is ever above maxFeeUsd.
    function check_setTiers_neverAboveCap(uint32 a, uint32 b, uint256 fa, uint256 fb, uint256 fc, uint256 n) public {
        uint32[] memory m = new uint32[](3);
        uint256[] memory f = new uint256[](3);
        (m[0], m[1], m[2]) = (a, b, 500);
        (f[0], f[1], f[2]) = (fa, fb, fc);
        vm.prank(owner);
        try ms.setTiers(m, f) {
            vm.assume(n >= 1 && n <= 500);
            assert(ms.feeUsdFor(n) <= ms.maxFeeUsd());
        } catch {}
    }

    /// S3: maxFeeUsd can only go down, and tiers above the new cap are cut to it.
    function check_lowerMaxFeeUsd_onlyDown(uint256 x, uint256 n) public {
        uint256 before = ms.maxFeeUsd();
        vm.prank(owner);
        try ms.lowerMaxFeeUsd(x) {
            assert(x <= before);
            assert(ms.maxFeeUsd() == x);
            vm.assume(n >= 1 && n <= 500);
            assert(ms.feeUsdFor(n) <= x);
        } catch {
            assert(x > before);
        }
    }

    /// S4: maxNativeCharge can only go down.
    function check_lowerMaxNativeCharge_onlyDown(uint256 x) public {
        uint256 before = ms.maxNativeCharge();
        vm.prank(owner);
        try ms.lowerMaxNativeCharge(x) {
            assert(x <= before && ms.maxNativeCharge() == x);
        } catch {
            assert(x > before);
        }
    }

    /// S5: a native send pays both recipients exactly, the treasury exactly the fee, refunds the rest,
    /// and leaves nothing in the contract. For any amounts, any coin price and any payment.
    function check_sendNative_exact(uint256 a1, uint256 a2, uint256 price, uint256 value) public {
        vm.assume(price > 1e6 && price < 1e15);
        vm.prank(owner);
        ms.setManualPrice(price);
        address sender = address(0x5E4D);
        vm.assume(value <= 1e30);
        vm.deal(sender, value);

        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](2);
        (r[0], r[1], a[0], a[1]) = (r1, r2, a1, a2);

        vm.prank(sender);
        try ms.sendNative{value: value}(r, a) returns (uint256 total) {
            uint256 fee = 0; // 2 recipients: free tier
            assert(total == a1 + a2);
            assert(r1.balance == a1 && r2.balance == a2);
            assert(treasury.balance == fee);
            assert(sender.balance == value - total - fee);
            assert(address(ms).balance == 0);
        } catch {
            // only when underpaid, a zero amount, or the sum overflows
            assert(a1 == 0 || a2 == 0 || a1 > type(uint256).max - a2 || value < a1 + a2);
        }
    }

    /// S6: nobody but the owner can change any setting or move funds.
    function check_onlyOwner(address caller, uint256 x, uint8 which) public {
        vm.assume(caller != owner);
        bytes memory data;
        uint8 w = which % 8;
        if (w == 0) data = abi.encodeCall(BulmoMultisend.setTreasury, (caller));
        else if (w == 1) data = abi.encodeCall(BulmoMultisend.lowerMaxFeeUsd, (x));
        else if (w == 2) data = abi.encodeCall(BulmoMultisend.setManualPrice, (x));
        else if (w == 3) data = abi.encodeCall(BulmoMultisend.lowerMaxNativeCharge, (x));
        else if (w == 4) data = abi.encodeCall(BulmoMultisend.sweep, (payable(caller)));
        else if (w == 5) data = abi.encodeWithSignature("transferOwnership(address)", caller);
        else if (w == 6) data = abi.encodeCall(BulmoMultisend.setPriceSource, (address(0), address(0), 0));
        else data = abi.encodeWithSignature("renounceOwnership()");
        vm.prank(caller);
        (bool ok,) = address(ms).call(data);
        assert(!ok);
        assert(ms.owner() == owner && ms.treasury() == treasury);
    }

    /// S7: only the buyer (owner) or an operator can send through a Personal Multisend.
    function check_personal_onlyOwnerOrOperator(address caller, uint256 amount) public {
        vm.prank(owner);
        factory.setManualPrice(3000e8);
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        address clone = factory.createPersonalMultisend{value: 10 ether}(bytes32(0));
        vm.assume(caller != owner);
        vm.assume(amount > 0 && amount < 1e30);
        vm.deal(caller, amount);

        address[] memory r = new address[](1);
        uint256[] memory a = new uint256[](1);
        (r[0], a[0]) = (r1, amount);
        vm.prank(caller);
        (bool ok,) = clone.call{value: amount}(abi.encodeCall(BulmoPersonalMultisend.sendNative, (r, a)));
        assert(!ok);
        assert(BulmoPersonalMultisend(clone).owner() == owner);
    }

    /// S8: a Personal Multisend purchase charges exactly the price; the rest is refunded.
    function check_buy_chargesExactly(uint256 price, uint256 value, bytes32 salt) public {
        vm.assume(price > 1e6 && price < 1e15 && value <= 1e30);
        vm.prank(owner);
        factory.setManualPrice(price);
        address buyer = address(0xB0E);
        vm.deal(buyer, value);
        uint256 charge = factory.currentPrice();
        vm.prank(buyer);
        try factory.createPersonalMultisend{value: value}(salt) returns (address clone) {
            assert(buyer.balance == value - charge);
            assert(treasury.balance == charge);
            assert(address(factory).balance == 0);
            assert(BulmoPersonalMultisend(clone).owner() == buyer);
        } catch {
            assert(value < charge);
        }
    }
}
