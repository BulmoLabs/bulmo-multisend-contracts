// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BulmoMultisend} from "../../src/BulmoMultisend.sol";
import {MockToken} from "../mocks/Tokens.sol";
import {MockAggregator} from "../mocks/MockFeeds.sol";
import {Handler} from "./Handler.sol";

/// Rules that must hold after ANY sequence of sends, fee changes, cap lowering and withdrawals.
contract BulmoMultisendInvariantTest is Test {
    BulmoMultisend ms;
    MockToken token;
    Handler handler;
    address owner = makeAddr("owner");
    uint256 constant INITIAL_MAX = 100e8; // $100
    uint256 constant INITIAL_NATIVE_CAP = 10 ether;

    function setUp() public {
        uint32[] memory m = new uint32[](4);
        (m[0], m[1], m[2], m[3]) = (5, 20, 50, 500);
        uint256[] memory f = new uint256[](4);
        (f[0], f[1], f[2], f[3]) = (0, 10e8, 19e8, 49e8); // Bulmo pricing
        vm.warp(1_700_000_000);
        ms = new BulmoMultisend(owner, INITIAL_MAX, INITIAL_NATIVE_CAP, m, f);
        MockAggregator feed = new MockAggregator(8, 2000e8);
        vm.prank(owner);
        ms.setPriceSource(address(feed), address(0), 1 hours);
        token = new MockToken("Token", "TKN", 18);
        handler = new Handler(ms, token, feed, owner);
        targetContract(address(handler));
    }

    /// Non-custodial: the contract never ends up holding user tokens.
    function invariant_neverHoldsTokens() public view {
        assertEq(token.balanceOf(address(ms)), 0);
    }

    /// Fees never stay in the contract: every wei charged reached a treasury in the same transaction.
    function invariant_neverHoldsNativeAndTreasuryGotEveryFee() public view {
        assertEq(address(ms).balance, 0);
        assertEq(owner.balance + handler.treasury().balance, handler.ghostFeesCollected());
    }

    /// No tier fee can ever exceed the cap, and every list size has a price.
    function invariant_feeNeverAboveCap() public view {
        (uint32[] memory m, uint256[] memory f) = ms.tiers();
        for (uint256 i; i < f.length; ++i) {
            assertLe(f[i], ms.maxFeeUsd());
        }
        assertEq(m[m.length - 1], ms.MAX_RECIPIENTS());
    }

    /// Both caps only ever go down: each equals the lowest value it was ever set to.
    function invariant_capsOnlyDecrease() public view {
        assertLe(ms.maxFeeUsd(), INITIAL_MAX);
        assertEq(ms.maxFeeUsd(), handler.ghostLowestMaxFeeUsd());
        assertLe(ms.maxNativeCharge(), INITIAL_NATIVE_CAP);
        assertEq(ms.maxNativeCharge(), handler.ghostLowestNativeCap());
    }

    /// Overpayment always comes back to the wei, at any price, and no fee ever exceeds the native cap.
    function invariant_refundsExactAndChargesCapped() public view {
        assertEq(handler.ghostBadRefunds(), 0);
        assertEq(handler.ghostChargesAboveCap(), 0);
    }

    /// Everything sent reached recipients: their combined balances equal the totals sent.
    function invariant_recipientsReceivedEverything() public view {
        uint256 nativeSum;
        uint256 tokenSum;
        for (uint256 i; i < handler.recipientCount(); ++i) {
            address r = handler.recipientAt(i);
            nativeSum += r.balance;
            tokenSum += token.balanceOf(r);
        }
        assertEq(nativeSum, handler.ghostNativeSentToRecipients());
        assertEq(tokenSum, handler.ghostTokensSentToRecipients());
    }

    /// Owner stays in place (renounce is disabled, no transfers in this run).
    function invariant_ownerUnchanged() public view {
        assertEq(ms.owner(), owner);
    }
}
