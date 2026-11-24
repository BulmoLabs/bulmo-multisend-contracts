// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BulmoMultisend} from "../../src/BulmoMultisend.sol";
import {MockToken} from "../mocks/Tokens.sol";
import {MockAggregator} from "../mocks/MockFeeds.sol";

/// Drives random sequences of user sends (with random overpayment), coin price moves and owner actions,
/// tracking what *should* be true.
contract Handler is Test {
    BulmoMultisend public ms;
    MockToken public token;
    MockAggregator public feed;
    address public owner;
    address public treasury = makeAddr("treasury");

    address[] internal senders;
    address[] internal pool; // recipients

    // ghost accounting
    uint256 public ghostFeesCollected;

    uint256 public ghostNativeSentToRecipients;
    uint256 public ghostTokensSentToRecipients;
    uint256 public ghostLowestMaxFeeUsd;
    uint256 public ghostLowestNativeCap;
    uint256 public ghostBadRefunds; // a sender not getting back exactly what they overpaid
    uint256 public ghostChargesAboveCap; // a fee charged above maxNativeCharge
    uint256 public calls;

    constructor(BulmoMultisend _ms, MockToken _token, MockAggregator _feed, address _owner) {
        ms = _ms;
        token = _token;
        feed = _feed;
        owner = _owner;
        ghostLowestMaxFeeUsd = _ms.maxFeeUsd();
        ghostLowestNativeCap = _ms.maxNativeCharge();
        for (uint256 i; i < 4; ++i) {
            senders.push(makeAddr(string.concat("sender", vm.toString(i))));
        }
        for (uint256 i; i < 12; ++i) {
            pool.push(makeAddr(string.concat("recipient", vm.toString(i))));
        }
    }

    function _batch(uint256 seed, uint256 maxEach)
        internal
        view
        returns (address[] memory r, uint256[] memory a, uint256 total)
    {
        uint256 n = bound(seed, 1, 30); // spans the 1-5, 6-20 and 21-50 tiers
        r = new address[](n);
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = pool[uint256(keccak256(abi.encode(seed, i))) % pool.length];
            a[i] = bound(uint256(keccak256(abi.encode(seed, i, 1))), 1, maxEach);
            total += a[i];
        }
    }

    /// Fee for n recipients, or false if the current price/cap make paid sends unavailable.
    function _fee(uint256 n) internal view returns (bool ok, uint256 fee) {
        try ms.feeFor(n) returns (uint256 f) {
            return (true, f);
        } catch {
            return (false, 0);
        }
    }

    function sendNative(uint256 senderSeed, uint256 seed, uint64 extra) external {
        address s = senders[senderSeed % senders.length];
        (address[] memory r, uint256[] memory a, uint256 total) = _batch(seed, 5 ether);
        (bool ok, uint256 fee) = _fee(r.length);
        if (!ok) return;
        vm.deal(s, total + fee + extra);
        vm.prank(s);
        ms.sendNative{value: total + fee + extra}(r, a);
        if (s.balance != extra) ghostBadRefunds++;
        if (fee > ms.maxNativeCharge()) ghostChargesAboveCap++;
        ghostFeesCollected += fee;
        ghostNativeSentToRecipients += total;
        calls++;
    }

    function sendToken(uint256 senderSeed, uint256 seed, uint64 extra) external {
        address s = senders[senderSeed % senders.length];
        (address[] memory r, uint256[] memory a, uint256 total) = _batch(seed, 1e24);
        (bool ok, uint256 fee) = _fee(r.length);
        if (!ok) return;
        token.mint(s, total);
        vm.deal(s, fee + extra);
        vm.startPrank(s);
        token.approve(address(ms), total);
        ms.sendToken{value: fee + extra}(token, r, a);
        vm.stopPrank();
        if (s.balance != extra) ghostBadRefunds++;
        if (fee > ms.maxNativeCharge()) ghostChargesAboveCap++;
        ghostFeesCollected += fee;
        ghostTokensSentToRecipients += total;
        calls++;
    }

    /// The coin's price moves anywhere between $1 and $100,000 (feed stays fresh).
    function movePrice(uint256 price) external {
        feed.set(int256(bound(price, 1e8, 1e13)), block.timestamp);
    }

    function setTiers(uint256 seed) external {
        uint32[] memory m = new uint32[](4);
        (m[0], m[1], m[2], m[3]) = (5, 20, 50, 500);
        uint256[] memory f = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            f[i] = bound(uint256(keccak256(abi.encode(seed, i))), 0, ms.maxFeeUsd());
        }
        vm.prank(owner);
        ms.setTiers(m, f);
    }

    function lowerMaxFeeUsd(uint256 newMax) external {
        newMax = bound(newMax, 0, ms.maxFeeUsd());
        vm.prank(owner);
        ms.lowerMaxFeeUsd(newMax);
        if (newMax < ghostLowestMaxFeeUsd) ghostLowestMaxFeeUsd = newMax;
    }

    function lowerMaxNativeCharge(uint256 newCap) external {
        uint256 cur = ms.maxNativeCharge();
        newCap = bound(newCap, cur / 2, cur); // drift down slowly so sends keep happening
        vm.prank(owner);
        ms.lowerMaxNativeCharge(newCap);
        if (newCap < ghostLowestNativeCap) ghostLowestNativeCap = newCap;
    }

    /// Fees go to whichever of the two treasuries is set at the time.
    function switchTreasury(bool toOwner) external {
        vm.prank(owner);
        ms.setTreasury(toOwner ? owner : treasury);
    }

    function recipientCount() external view returns (uint256) {
        return pool.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return pool[i];
    }

    function senderCount() external view returns (uint256) {
        return senders.length;
    }
}
