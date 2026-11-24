// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BulmoMultisend} from "../src/BulmoMultisend.sol";
import {MultisendCore} from "../src/MultisendCore.sol";
import {MockToken, TaxToken, NoReturnToken, FalseReturnToken, ReentrantToken} from "./mocks/Tokens.sol";
import {
    RejectingReceiver,
    AcceptingReceiver,
    ReentrantReceiver,
    GasGuzzler,
    ReturnBombReceiver
} from "./mocks/Receivers.sol";
import {MockAggregator} from "./mocks/MockFeeds.sol";
import {UsdPricing} from "../src/UsdPricing.sol";

contract BulmoMultisendTest is Test {
    BulmoMultisend ms;
    MockToken usdc;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice"); // sender
    address treasury = makeAddr("treasury");

    // Prices are in USD (8 decimals); a mock Chainlink feed at ETH = $2,000 turns them into the wei below.
    // Test tiers: every tier paid so small-list tests exercise the fee. The product's free tier is tested separately.
    uint256 constant ETH_USD = 2000e8;
    uint256 constant MAX_FEE_USD = 100e8; // $100 cap
    uint256 constant MAX_NATIVE = 10 ether;
    uint256 constant U = 2e8; //   $2  -> 0.001 ETH (1-5 recipients)
    uint256 constant U20 = 20e8; // $20 -> 0.01 ETH (6-20)
    uint256 constant U50 = 38e8; // $38 -> 0.019 ETH (21-50)
    uint256 constant UMAX = 58e8; // $58 -> 0.029 ETH (51-500)
    uint256 constant FEE = 0.001 ether;
    uint256 constant FEE_20 = 0.01 ether;
    uint256 constant FEE_50 = 0.019 ether;
    uint256 constant FEE_MAX = 0.029 ether;
    uint256 constant MAX_FEE = 0.05 ether; // MAX_FEE_USD in wei at $2,000
    MockAggregator feed;

    event NativeMultisent(address indexed sender, uint256 recipients, uint256 total, uint256 fee);
    event TokenMultisent(address indexed sender, address indexed token, uint256 recipients, uint256 total, uint256 fee);
    event TiersUpdated(uint32[] maxRecipients, uint256[] feesUsd);
    event MaxFeeUsdLowered(uint256 previousMaxFeeUsd, uint256 newMaxFeeUsd);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event Swept(address indexed to, uint256 amount);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    function _caps() internal pure returns (uint32[] memory m) {
        m = new uint32[](4);
        m[0] = 5;
        m[1] = 20;
        m[2] = 50;
        m[3] = 500;
    }

    function _fees(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory f) {
        f = new uint256[](4);
        f[0] = a;
        f[1] = b;
        f[2] = c;
        f[3] = d;
    }

    /// Sets every tier to the same USD fee.
    function _setFlat(uint256 feeUsd) internal {
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(feeUsd, feeUsd, feeUsd, feeUsd));
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockAggregator(8, int256(ETH_USD));
        ms = new BulmoMultisend(owner, MAX_FEE_USD, MAX_NATIVE, _caps(), _fees(U, U20, U50, UMAX));
        vm.startPrank(owner);
        ms.setPriceSource(address(feed), address(0), 1 hours);
        ms.setTreasury(treasury); // fees land here in every paid send
        vm.stopPrank();
        usdc = new MockToken("USD Coin", "USDC", 6);
        vm.deal(alice, 1_000 ether);
        usdc.mint(alice, 1_000_000e6);
    }

    // ------------------------------------------------------------ helpers

    function _recipients(uint256 n) internal returns (address[] memory r) {
        r = new address[](n);
        for (uint256 i; i < n; ++i) {
            r[i] = makeAddr(string.concat("r", vm.toString(i)));
        }
    }

    function _amounts(uint256 n, uint256 each) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = each;
        }
    }

    function _one(address r, uint256 amount) internal pure returns (address[] memory rs, uint256[] memory as_) {
        rs = new address[](1);
        as_ = new uint256[](1);
        rs[0] = r;
        as_[0] = amount;
    }

    // ------------------------------------------------------------ deployment

    function test_constructor_setsState() public view {
        assertEq(ms.owner(), owner);
        assertEq(ms.maxFeeUsd(), MAX_FEE_USD);
        assertEq(ms.maxNativeCharge(), MAX_NATIVE);
        assertEq(ms.priceFeed(), address(feed));
        assertEq(ms.MAX_RECIPIENTS(), 500);
        assertEq(ms.MAX_TIERS(), 5);
        assertEq(ms.VERSION(), "1.0.0");
        (uint32[] memory m, uint256[] memory f) = ms.tiers();
        assertEq(m.length, 4);
        assertEq(m[3], 500);
        assertEq(f[0], U);
        assertEq(f[3], UMAX);
    }

    function test_constructor_revertsIfTierFeeAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.FeeAboveMax.selector, 2, 1));
        new BulmoMultisend(owner, 1, MAX_NATIVE, _caps(), _fees(0, 0, 2, 0));
    }

    function test_constructor_revertsIfCapTooLargeToStore() public {
        uint256 tooBig = uint256(type(uint224).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.FeeAboveMax.selector, tooBig, type(uint224).max));
        new BulmoMultisend(owner, tooBig, MAX_NATIVE, _caps(), _fees(0, 0, 0, 0));
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BulmoMultisend(address(0), MAX_FEE_USD, MAX_NATIVE, _caps(), _fees(0, 0, 0, 0));
    }

    function test_constructor_allFreeAllowed() public {
        BulmoMultisend free = new BulmoMultisend(owner, 0, 0, _caps(), _fees(0, 0, 0, 0)); // no price source needed when free
        assertEq(free.feeFor(1), 0);
        assertEq(free.feeFor(500), 0);
    }

    // ------------------------------------------------------------ tiers (Bulmo pricing: 1-5 free, 6-20, 21-50, 51+)

    function test_feeFor_tierBoundaries() public view {
        assertEq(ms.feeFor(1), FEE);
        assertEq(ms.feeFor(5), FEE);
        assertEq(ms.feeFor(6), FEE_20);
        assertEq(ms.feeFor(20), FEE_20);
        assertEq(ms.feeFor(21), FEE_50);
        assertEq(ms.feeFor(50), FEE_50);
        assertEq(ms.feeFor(51), FEE_MAX);
        assertEq(ms.feeFor(500), FEE_MAX);
    }

    function test_feeFor_revertsAboveMaxRecipients() public {
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.TooManyRecipients.selector, 501, 500));
        ms.feeFor(501);
    }

    function test_freeTier_upToFiveWalletsPaysNothing() public {
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(0, U20, U50, UMAX)); // Bulmo's real pricing shape
        address[] memory r = _recipients(5);
        vm.prank(alice);
        ms.sendNative{value: 5 ether}(r, _amounts(5, 1 ether));
        assertEq(treasury.balance, 0, "no fee for 5 wallets");

        address[] memory r6 = _recipients(6);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, 6 ether + FEE_20, 6 ether));
        vm.prank(alice);
        ms.sendNative{value: 6 ether}(r6, _amounts(6, 1 ether)); // the 6th wallet needs the paid tier
    }

    function test_tokenSend_feeFollowsTier() public {
        address[] memory r = _recipients(21);
        vm.startPrank(alice);
        usdc.approve(address(ms), 21e6);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, FEE_50, FEE_20));
        ms.sendToken{value: FEE_20}(usdc, r, _amounts(21, 1e6)); // 21 wallets is the 21-50 tier
        ms.sendToken{value: FEE_50}(usdc, r, _amounts(21, 1e6));
        vm.stopPrank();
        assertEq(treasury.balance, FEE_50);
    }

    function test_setTiers_replacesTableAndEmits() public {
        uint32[] memory m = new uint32[](2);
        m[0] = 10;
        m[1] = 500;
        uint256[] memory f = new uint256[](2);
        f[0] = 0;
        f[1] = U;
        vm.expectEmit(false, false, false, true, address(ms));
        emit TiersUpdated(m, f);
        vm.prank(owner);
        ms.setTiers(m, f);
        assertEq(ms.feeFor(10), 0);
        assertEq(ms.feeFor(11), FEE);
        (uint32[] memory mm,) = ms.tiers();
        assertEq(mm.length, 2);
    }

    function test_setTiers_rejectsBadTables() public {
        vm.startPrank(owner);
        // empty
        vm.expectRevert(BulmoMultisend.InvalidTiers.selector);
        ms.setTiers(new uint32[](0), new uint256[](0));
        // length mismatch
        vm.expectRevert(BulmoMultisend.InvalidTiers.selector);
        ms.setTiers(_caps(), new uint256[](3));
        // too many tiers
        uint32[] memory six = new uint32[](6);
        for (uint32 i; i < 6; ++i) {
            six[i] = i == 5 ? 500 : (i + 1) * 10;
        }
        vm.expectRevert(BulmoMultisend.InvalidTiers.selector);
        ms.setTiers(six, new uint256[](6));
        // last tier must cover MAX_RECIPIENTS
        uint32[] memory short_ = _caps();
        short_[3] = 499;
        vm.expectRevert(BulmoMultisend.InvalidTiers.selector);
        ms.setTiers(short_, _fees(0, 0, 0, 0));
        // not ascending
        uint32[] memory unsorted = _caps();
        unsorted[1] = 5;
        vm.expectRevert(BulmoMultisend.InvalidTiers.selector);
        ms.setTiers(unsorted, _fees(0, 0, 0, 0));
        // first bound zero
        uint32[] memory zero = _caps();
        zero[0] = 0;
        vm.expectRevert(BulmoMultisend.InvalidTiers.selector);
        ms.setTiers(zero, _fees(0, 0, 0, 0));
        // fee above cap
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.FeeAboveMax.selector, MAX_FEE_USD + 1, MAX_FEE_USD));
        ms.setTiers(_caps(), _fees(0, 0, 0, MAX_FEE_USD + 1));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ fee-change protection (extra cases)

    function test_tierBoundaryChangedAfterReview_reverts() public {
        // Product pricing: 1-5 free. A user reviews a free 4-wallet send...
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(0, U20, U50, UMAX));
        address[] memory r = _recipients(4);
        uint256 reviewedFee = ms.feeFor(4);
        assertEq(reviewedFee, 0);

        // ...then the owner shrinks the free tier to 3 wallets before the user's transaction lands.
        uint32[] memory m = _caps();
        m[0] = 3;
        vm.prank(owner);
        ms.setTiers(m, _fees(0, U20, U50, UMAX));

        // The user's transaction (built with the reviewed fee) fails instead of charging $10.
        vm.expectRevert(
            abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, 4 ether + FEE_20, 4 ether + reviewedFee)
        );
        vm.prank(alice);
        ms.sendNative{value: 4 ether + reviewedFee}(r, _amounts(4, 1 ether));
    }

    function test_feeChangesAreAlwaysPublic() public {
        // Every pricing change emits an event, so anyone (and the dapp) can monitor it.
        vm.recordLogs();
        vm.startPrank(owner);
        ms.setTiers(_caps(), _fees(0, 0, 0, 0));
        ms.lowerMaxFeeUsd(MAX_FEE_USD / 2);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 2, "TiersUpdated + MaxFeeUsdLowered");
    }

    // ------------------------------------------------------------ limits

    function test_limits_constants() public view {
        assertEq(ms.MAX_RECIPIENTS(), 500);
        assertEq(ms.MAX_TIERS(), 5);
    }

    function test_setTiers_acceptsExactlyMaxTiers() public {
        uint32[] memory m = new uint32[](5);
        (m[0], m[1], m[2], m[3], m[4]) = (5, 20, 50, 100, 500);
        uint256[] memory f = new uint256[](5);
        (f[0], f[1], f[2], f[3], f[4]) = (0, U, U20, U50, UMAX);
        vm.prank(owner);
        ms.setTiers(m, f);
        assertEq(ms.feeFor(100), FEE_50);
        assertEq(ms.feeFor(101), FEE_MAX);
    }

    function test_setTiers_acceptsSingleFlatTier() public {
        uint32[] memory m = new uint32[](1);
        m[0] = 500;
        uint256[] memory f = new uint256[](1);
        f[0] = U;
        vm.prank(owner);
        ms.setTiers(m, f);
        assertEq(ms.feeFor(1), FEE);
        assertEq(ms.feeFor(500), FEE);
    }

    function test_sendToken_maxRecipients() public {
        address[] memory r = _recipients(500);
        vm.startPrank(alice);
        usdc.approve(address(ms), 500e6);
        ms.sendToken{value: FEE_MAX}(usdc, r, _amounts(500, 1e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(r[499]), 1e6);
    }

    function test_sendToken_revertsTooManyRecipients() public {
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.TooManyRecipients.selector, 501, 500));
        vm.prank(alice);
        ms.sendToken{value: FEE_MAX}(usdc, new address[](501), new uint256[](501));
    }

    function test_maxAmountPerRecipient() public {
        // A single huge amount is fine as long as the total doesn't overflow.
        usdc.mint(alice, type(uint128).max);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("whale"), type(uint128).max);
        vm.startPrank(alice);
        usdc.approve(address(ms), type(uint128).max);
        ms.sendToken{value: FEE}(usdc, r, a);
        vm.stopPrank();
        assertEq(usdc.balanceOf(r[0]), type(uint128).max);
    }

    function test_setTiers_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.setTiers(_caps(), _fees(0, 0, 0, 0));
    }

    // ------------------------------------------------------------ sendNative: happy paths

    function test_sendNative_paysEveryoneAndKeepsOnlyTheFee() public {
        address[] memory r = _recipients(3);
        uint256[] memory a = new uint256[](3);
        a[0] = 1 ether;
        a[1] = 2 ether;
        a[2] = 0.5 ether;

        vm.prank(alice);
        uint256 total = ms.sendNative{value: 3.5 ether + FEE}(r, a);

        assertEq(total, 3.5 ether);
        assertEq(r[0].balance, 1 ether);
        assertEq(r[1].balance, 2 ether);
        assertEq(r[2].balance, 0.5 ether);
        assertEq(treasury.balance, FEE, "contract keeps exactly the fee");
        assertEq(alice.balance, 1_000 ether - 3.5 ether - FEE);
    }

    function test_sendNative_emitsEvent() public {
        address[] memory r = _recipients(2);
        uint256[] memory a = _amounts(2, 1 ether);
        vm.expectEmit(true, false, false, true, address(ms));
        emit NativeMultisent(alice, 2, 2 ether, FEE);
        vm.prank(alice);
        ms.sendNative{value: 2 ether + FEE}(r, a);
    }

    function test_sendNative_withZeroFee() public {
        _setFlat(0);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.prank(alice);
        ms.sendNative{value: 1 ether}(r, a);
        assertEq(treasury.balance, 0);
    }

    function test_sendNative_duplicateRecipientsArePaidEachTime() public {
        address bob = makeAddr("bob");
        address[] memory r = new address[](2);
        r[0] = bob;
        r[1] = bob;
        vm.prank(alice);
        ms.sendNative{value: 3 ether + FEE}(r, _amounts(2, 1.5 ether));
        assertEq(bob.balance, 3 ether);
    }

    function test_sendNative_toContractWallet() public {
        AcceptingReceiver safe = new AcceptingReceiver();
        (address[] memory r, uint256[] memory a) = _one(address(safe), 1 ether);
        vm.prank(alice);
        ms.sendNative{value: 1 ether + FEE}(r, a);
        assertEq(safe.received(), 1 ether);
    }

    function test_sendNative_maxRecipients() public {
        address[] memory r = _recipients(500);
        vm.prank(alice);
        ms.sendNative{value: 500 * 0.01 ether + FEE_MAX}(r, _amounts(500, 0.01 ether));
        assertEq(r[499].balance, 0.01 ether);
    }

    // ------------------------------------------------------------ sendNative: value checks

    function test_sendNative_revertsWhenValueTooLow() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, 1 ether + FEE, 1 ether));
        vm.prank(alice);
        ms.sendNative{value: 1 ether}(r, a); // forgot the fee
    }

    function test_sendNative_refundsOverpayment() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.prank(alice);
        ms.sendNative{value: 2 ether}(r, a); // pays 1 ETH + fee, gets the rest back
        assertEq(r[0].balance, 1 ether);
        assertEq(treasury.balance, FEE, "only the fee stays");
        assertEq(alice.balance, 1_000 ether - 1 ether - FEE, "excess refunded");
    }

    function test_sendNative_revertsIfFeeRaisedAfterReview() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        uint256 reviewedValue = 1 ether + ms.feeFor(1);
        _setFlat(MAX_FEE_USD); // fee changes between review and send
        vm.expectRevert(
            abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, 1 ether + MAX_FEE, reviewedValue)
        );
        vm.prank(alice);
        ms.sendNative{value: reviewedValue}(r, a);
    }

    function test_sendNative_feeLoweredAfterReviewChargesLess() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        uint256 reviewedValue = 1 ether + ms.feeFor(1);
        _setFlat(0);
        vm.prank(alice);
        ms.sendNative{value: reviewedValue}(r, a);
        assertEq(treasury.balance, 0, "new, lower fee charged");
        assertEq(alice.balance, 1_000 ether - 1 ether, "difference refunded");
    }

    // ------------------------------------------------------------ sendNative: input validation

    function test_sendNative_revertsNoRecipients() public {
        vm.expectRevert(MultisendCore.NoRecipients.selector);
        vm.prank(alice);
        ms.sendNative{value: FEE}(new address[](0), new uint256[](0));
    }

    function test_sendNative_revertsTooManyRecipients() public {
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.TooManyRecipients.selector, 501, 500));
        vm.prank(alice);
        ms.sendNative{value: FEE}(new address[](501), new uint256[](501));
    }

    function test_sendNative_revertsLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.LengthMismatch.selector, 2, 1));
        vm.prank(alice);
        ms.sendNative{value: 1 ether + FEE}(_recipients(2), _amounts(1, 1 ether));
    }

    function test_sendNative_revertsZeroAddressRecipient() public {
        address[] memory r = _recipients(3);
        r[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.ZeroAddressRecipient.selector, 1));
        vm.prank(alice);
        ms.sendNative{value: 3 ether + FEE}(r, _amounts(3, 1 ether));
    }

    function test_sendNative_revertsZeroAmount() public {
        uint256[] memory a = _amounts(3, 1 ether);
        a[2] = 0;
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.ZeroAmount.selector, 2));
        vm.prank(alice);
        ms.sendNative{value: 2 ether + FEE}(_recipients(3), a);
    }

    function test_sendNative_revertsOnAmountOverflow() public {
        uint256[] memory a = new uint256[](2);
        a[0] = type(uint256).max;
        a[1] = 1;
        vm.expectRevert(); // arithmetic overflow panic
        vm.prank(alice);
        ms.sendNative{value: 1}(_recipients(2), a);
    }

    // ------------------------------------------------------------ sendNative: all-or-nothing + attacks

    function test_sendNative_allOrNothingWhenARecipientRejects() public {
        address[] memory r = _recipients(3);
        r[1] = address(new RejectingReceiver());
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.NativeTransferFailed.selector, 1, r[1]));
        vm.prank(alice);
        ms.sendNative{value: 3 ether + FEE}(r, _amounts(3, 1 ether));
        assertEq(r[0].balance, 0, "first recipient not paid either");
        assertEq(alice.balance, 1_000 ether, "sender keeps everything");
    }

    function test_sendNative_blocksReentrancy() public {
        ReentrantReceiver evil = new ReentrantReceiver(address(ms));
        (address[] memory r, uint256[] memory a) = _one(address(evil), 1 ether);
        // The inner call hits ReentrancyGuard, so the evil receiver reverts and the whole send fails.
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.NativeTransferFailed.selector, 0, address(evil)));
        vm.prank(alice);
        ms.sendNative{value: 1 ether + FEE}(r, a);
        assertFalse(evil.reentered());
    }

    function test_sendNative_gasGuzzlerCannotPartiallyPay() public {
        address[] memory r = _recipients(2);
        r[1] = address(new GasGuzzler());
        vm.prank(alice);
        (bool ok,) = address(ms).call{value: 2 ether + FEE, gas: 1_000_000}(
            abi.encodeCall(BulmoMultisend.sendNative, (r, _amounts(2, 1 ether)))
        );
        assertFalse(ok);
        assertEq(r[0].balance, 0);
        assertEq(treasury.balance, 0);
    }

    function test_sendNative_largeReturnDataIsIgnored() public {
        // A recipient that returns 100 KB is still paid, and the send pays nothing to copy that data.
        address big = address(new ReturnBombReceiver());
        address[] memory r = _recipients(3);
        r[1] = big;
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        ms.sendNative{value: 3 ether + FEE}(r, _amounts(3, 1 ether));
        uint256 used = gasBefore - gasleft();
        assertEq(big.balance, 1 ether);
        assertEq(r[2].balance, 1 ether);
        // Copying 100 KB of return data would cost ~29k gas on top; the whole send stays well below that budget overrun.
        assertLt(used, 200_000);
    }

    function test_directNativeTransferReverts() public {
        vm.prank(alice);
        (bool ok,) = address(ms).call{value: 1 ether}("");
        assertFalse(ok, "no receive(): coins can't be sent here by accident");
    }

    // ------------------------------------------------------------ sendToken: happy paths

    function test_sendToken_paysStraightFromSender() public {
        address[] memory r = _recipients(3);
        uint256[] memory a = new uint256[](3);
        a[0] = 1_250e6;
        a[1] = 800e6;
        a[2] = 50e6;
        vm.startPrank(alice);
        usdc.approve(address(ms), 2_100e6);
        uint256 total = ms.sendToken{value: FEE}(usdc, r, a);
        vm.stopPrank();

        assertEq(total, 2_100e6);
        assertEq(usdc.balanceOf(r[0]), 1_250e6);
        assertEq(usdc.balanceOf(r[1]), 800e6);
        assertEq(usdc.balanceOf(r[2]), 50e6);
        assertEq(usdc.balanceOf(address(ms)), 0, "contract never holds tokens");
        assertEq(usdc.allowance(alice, address(ms)), 0, "exact approval fully used");
        assertEq(treasury.balance, FEE);
    }

    function test_sendToken_emitsEvent() public {
        address[] memory r = _recipients(2);
        vm.startPrank(alice);
        usdc.approve(address(ms), 2e6);
        vm.expectEmit(true, true, false, true, address(ms));
        emit TokenMultisent(alice, address(usdc), 2, 2e6, FEE);
        ms.sendToken{value: FEE}(usdc, r, _amounts(2, 1e6));
        vm.stopPrank();
    }

    function test_sendToken_usdtStyleNoReturnValue() public {
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(alice, 100e6);
        address[] memory r = _recipients(2);
        vm.startPrank(alice);
        usdt.approve(address(ms), 100e6);
        ms.sendToken{value: FEE}(IERC20(address(usdt)), r, _amounts(2, 50e6));
        vm.stopPrank();
        assertEq(usdt.balanceOf(r[0]), 50e6);
        assertEq(usdt.balanceOf(r[1]), 50e6);
    }

    function test_sendToken_taxTokenDeliversLessButNothingStuck() public {
        TaxToken tax = new TaxToken(500); // 5%
        tax.mint(alice, 1_000e18);
        address[] memory r = _recipients(2);
        vm.startPrank(alice);
        tax.approve(address(ms), 200e18);
        ms.sendToken{value: FEE}(IERC20(address(tax)), r, _amounts(2, 100e18));
        vm.stopPrank();
        assertEq(tax.balanceOf(r[0]), 95e18);
        assertEq(tax.balanceOf(address(ms)), 0);
    }

    // ------------------------------------------------------------ sendToken: failures

    function test_sendToken_revertsWhenFeeMissing() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1e6);
        vm.startPrank(alice);
        usdc.approve(address(ms), 1e6);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, FEE, 0));
        ms.sendToken(usdc, r, a);
        vm.stopPrank();
    }

    function test_sendToken_refundsValueAboveFee() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1e6);
        vm.startPrank(alice);
        usdc.approve(address(ms), 1e6);
        ms.sendToken{value: FEE * 3}(usdc, r, a);
        vm.stopPrank();
        assertEq(treasury.balance, FEE);
        assertEq(alice.balance, 1_000 ether - FEE);
    }

    function test_sendToken_revertsIfFeeChangedAfterReview() public {
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1e6);
        _setFlat(U * 2);
        vm.startPrank(alice);
        usdc.approve(address(ms), 1e6);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.InsufficientValue.selector, FEE * 2, FEE));
        ms.sendToken{value: FEE}(usdc, r, a);
        vm.stopPrank();
    }

    function test_sendToken_revertsOnInsufficientAllowance() public {
        address[] memory r = _recipients(2);
        vm.startPrank(alice);
        usdc.approve(address(ms), 1e6); // needs 2e6
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(ms), 0, 1e6));
        ms.sendToken{value: FEE}(usdc, r, _amounts(2, 1e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(r[0]), 0, "first transfer rolled back");
    }

    function test_sendToken_revertsOnInsufficientBalance() public {
        address poor = makeAddr("poor");
        vm.deal(poor, 1 ether);
        usdc.mint(poor, 1e6);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 2e6);
        vm.startPrank(poor);
        usdc.approve(address(ms), 2e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 1e6, 2e6));
        ms.sendToken{value: FEE}(usdc, r, a);
        vm.stopPrank();
    }

    function test_sendToken_revertsWhenTokenReturnsFalse() public {
        FalseReturnToken bad = new FalseReturnToken();
        bad.mint(alice, 1e6);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 5e6); // more than balance -> returns false
        vm.startPrank(alice);
        bad.approve(address(ms), 5e6);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        ms.sendToken{value: FEE}(IERC20(address(bad)), r, a);
        vm.stopPrank();
    }

    function test_sendToken_revertsForNonContractToken() public {
        address notAToken = makeAddr("eoa");
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, notAToken));
        vm.prank(alice);
        ms.sendToken{value: FEE}(IERC20(notAToken), r, a);
    }

    function test_sendToken_blocksReentrantToken() public {
        ReentrantToken evil = new ReentrantToken();
        evil.mint(alice, 10e18);
        evil.setTarget(address(ms));
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1e18);
        vm.startPrank(alice);
        evil.approve(address(ms), 1e18);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        ms.sendToken{value: FEE}(IERC20(address(evil)), r, a);
        vm.stopPrank();
    }

    function test_sendToken_validatesInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(MultisendCore.NoRecipients.selector);
        ms.sendToken{value: FEE}(usdc, new address[](0), new uint256[](0));

        vm.expectRevert(abi.encodeWithSelector(MultisendCore.LengthMismatch.selector, 1, 2));
        ms.sendToken{value: FEE}(usdc, _recipients(1), _amounts(2, 1));

        address[] memory r = _recipients(2);
        r[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.ZeroAddressRecipient.selector, 0));
        ms.sendToken{value: FEE}(usdc, r, _amounts(2, 1));

        uint256[] memory a = _amounts(2, 1);
        a[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.ZeroAmount.selector, 1));
        ms.sendToken{value: FEE}(usdc, _recipients(2), a);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ fee cap

    function test_lowerMaxFeeUsd_lowersCapAndClampsTiers() public {
        uint256 newMax = U20; // below U50 and UMAX
        vm.expectEmit(false, false, false, true, address(ms));
        emit MaxFeeUsdLowered(MAX_FEE_USD, newMax);
        vm.expectEmit(false, false, false, true, address(ms));
        emit TiersUpdated(_caps(), _fees(U, U20, U20, U20));
        vm.prank(owner);
        ms.lowerMaxFeeUsd(newMax);
        assertEq(ms.maxFeeUsd(), newMax);
        assertEq(ms.feeFor(5), FEE, "below the cap: unchanged");
        assertEq(ms.feeFor(50), FEE_20, "clamped");
        assertEq(ms.feeFor(500), FEE_20, "clamped");
    }

    function test_lowerMaxFeeUsd_keepsTiersIfAllBelow() public {
        vm.recordLogs();
        vm.prank(owner);
        ms.lowerMaxFeeUsd(UMAX);
        assertEq(vm.getRecordedLogs().length, 1, "only MaxFeeUsdLowered, no TiersUpdated");
        assertEq(ms.feeFor(500), FEE_MAX);
    }

    function test_lowerMaxFeeUsd_canNeverRaise() public {
        vm.startPrank(owner);
        ms.lowerMaxFeeUsd(U);
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.MaxFeeCanOnlyDecrease.selector, U, MAX_FEE_USD));
        ms.lowerMaxFeeUsd(MAX_FEE_USD);
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisend.FeeAboveMax.selector, U + 1, U));
        ms.setTiers(_caps(), _fees(0, 0, 0, U + 1));
        vm.stopPrank();
    }

    function test_lowerMaxFeeUsd_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.lowerMaxFeeUsd(0);
    }

    // ------------------------------------------------------------ oracle: Chainlink price, sequencer, manual mode

    event PriceSourceUpdated(address indexed priceFeed, address indexed sequencerFeed, uint32 maxPriceAge);
    event ManualPriceUpdated(uint256 previousPrice, uint256 newPrice);
    event MaxNativeChargeLowered(uint256 previousCap, uint256 newCap);

    function test_oracle_feeFollowsCoinPrice() public {
        assertEq(ms.feeFor(1), FEE); // $2 at $2,000
        feed.set(4000e8, block.timestamp);
        assertEq(ms.feeFor(1), FEE / 2, "coin doubles: fee in coin halves");
        feed.set(1000e8, block.timestamp);
        assertEq(ms.feeFor(1), FEE * 2);
    }

    function test_oracle_roundsUpNeverUndercharges() public {
        feed.set(3000e8, block.timestamp); // $2 / $3,000 = 0.000666... ETH
        assertEq(ms.feeFor(1), 666_666_666_666_667);
    }

    function test_oracle_staleAnswerReverts() public {
        uint256 updated = block.timestamp - 1 hours - 1;
        feed.set(int256(ETH_USD), updated);
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.StalePrice.selector, updated, 1 hours));
        ms.feeFor(1);
        feed.set(int256(ETH_USD), block.timestamp - 1 hours); // exactly at the limit: fine
        assertEq(ms.feeFor(1), FEE);
    }

    function test_oracle_badAnswersRevert() public {
        feed.set(0, block.timestamp);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        ms.feeFor(1);
        feed.set(-1, block.timestamp);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        ms.feeFor(1);
        feed.set(int256(ETH_USD), 0); // never updated
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        ms.feeFor(1);
        feed.set(int256(ETH_USD), block.timestamp + 1); // from the future
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        ms.feeFor(1);
    }

    function test_oracle_paidSendRevertsButFreeSendWorksWhenFeedBroken() public {
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(0, U20, U50, UMAX));
        feed.set(0, block.timestamp);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.prank(alice);
        ms.sendNative{value: 1 ether}(r, a); // 1 wallet: free, no oracle needed
        assertEq(r[0].balance, 1 ether);

        address[] memory r6 = _recipients(6);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        vm.prank(alice);
        ms.sendNative{value: 7 ether}(r6, _amounts(6, 1 ether));
    }

    function test_oracle_feedDecimalsScaled() public {
        MockAggregator f18 = new MockAggregator(18, int256(2000e18));
        MockAggregator f6 = new MockAggregator(6, int256(2000e6));
        vm.startPrank(owner);
        ms.setPriceSource(address(f18), address(0), 1 hours);
        assertEq(ms.priceFeedDecimals(), 18);
        assertEq(ms.feeFor(1), FEE);
        ms.setPriceSource(address(f6), address(0), 1 hours);
        assertEq(ms.feeFor(1), FEE);
        vm.stopPrank();
        (uint256 p,) = ms.nativeUsdPrice();
        assertEq(p, ETH_USD);
    }

    function test_oracle_tinyHighDecimalAnswerRoundingToZeroReverts() public {
        MockAggregator f18 = new MockAggregator(18, 1); // 1e-18 dollars: scales to 0 at 8 decimals
        vm.prank(owner);
        ms.setPriceSource(address(f18), address(0), 1 hours);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        ms.feeFor(1);
    }

    function test_oracle_sequencerDownAndGracePeriod() public {
        MockAggregator seq = new MockAggregator(0, 0); // 0 = up
        seq.setStartedAt(block.timestamp - 2 hours);
        vm.prank(owner);
        ms.setPriceSource(address(feed), address(seq), 1 hours);
        assertEq(ms.feeFor(1), FEE);

        seq.set(1, block.timestamp); // sequencer down
        vm.expectRevert(UsdPricing.SequencerDown.selector);
        ms.feeFor(1);

        seq.set(0, block.timestamp); // back up, just restarted
        uint256 upSince = block.timestamp - 10 minutes;
        seq.setStartedAt(upSince);
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.SequencerGracePeriod.selector, upSince));
        ms.feeFor(1);

        seq.setStartedAt(block.timestamp - 1 hours); // exactly the grace period: still waiting
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.SequencerGracePeriod.selector, block.timestamp - 1 hours));
        ms.feeFor(1);

        seq.setStartedAt(block.timestamp - 1 hours - 1);
        assertEq(ms.feeFor(1), FEE);

        seq.setStartedAt(0); // invalid round
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.SequencerGracePeriod.selector, 0));
        ms.feeFor(1);
    }

    function test_oracle_manualMode() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(ms));
        emit PriceSourceUpdated(address(0), address(0), 0);
        ms.setPriceSource(address(0), address(0), 0);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector); // not configured yet
        ms.feeFor(1);
        vm.expectEmit(false, false, false, true, address(ms));
        emit ManualPriceUpdated(0, 40e8);
        ms.setManualPrice(40e8); // e.g. HYPE = $40 on Elysium
        vm.stopPrank();
        assertEq(ms.feeFor(1), 0.05 ether); // $2 / $40
        (uint256 p, uint256 at) = ms.nativeUsdPrice();
        assertEq(p, 40e8);
        assertEq(at, block.timestamp);
        // a feed set later takes over from the manual price
        vm.prank(owner);
        ms.setPriceSource(address(feed), address(0), 1 hours);
        assertEq(ms.feeFor(1), FEE);
    }

    function test_oracle_noSourceConfigured() public {
        BulmoMultisend fresh = new BulmoMultisend(owner, MAX_FEE_USD, MAX_NATIVE, _caps(), _fees(0, U20, U50, UMAX));
        assertEq(fresh.feeFor(5), 0, "free tier needs no price");
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        fresh.feeFor(6);
    }

    function test_setPriceSource_validates() public {
        vm.startPrank(owner);
        vm.expectRevert(UsdPricing.InvalidPriceSource.selector);
        ms.setPriceSource(address(feed), address(0), 0); // feed needs a max age
        MockAggregator f19 = new MockAggregator(19, 1);
        vm.expectRevert(UsdPricing.InvalidPriceSource.selector);
        ms.setPriceSource(address(f19), address(0), 1 hours);
        vm.expectRevert(UsdPricing.InvalidPriceSource.selector);
        ms.setPriceSource(address(0), address(feed), 0); // manual mode takes no sequencer
        vm.expectRevert(UsdPricing.InvalidPriceSource.selector);
        ms.setPriceSource(address(0), address(0), 1); // ... and no max age
        vm.expectRevert(); // not a feed at all
        ms.setPriceSource(makeAddr("eoa"), address(0), 1 hours);

        vm.expectEmit(true, true, false, true, address(ms));
        emit PriceSourceUpdated(address(feed), address(0), 2 hours);
        ms.setPriceSource(address(feed), address(0), 2 hours);
        vm.stopPrank();
        assertEq(ms.maxPriceAge(), 2 hours);
    }

    function test_pricingAdmin_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ms.setPriceSource(address(0), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ms.setManualPrice(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ms.lowerMaxNativeCharge(0);
        vm.stopPrank();
    }

    function test_nativeCap_blocksAbsurdChargeFromBrokenFeed() public {
        feed.set(1e6, block.timestamp); // feed glitches to $0.01: $58 would be 5,800 ETH
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.NativeChargeAboveCap.selector, 5_800 ether, MAX_NATIVE));
        ms.feeFor(500);
        address[] memory r = _recipients(51);
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.NativeChargeAboveCap.selector, 5_800 ether, MAX_NATIVE));
        vm.prank(alice);
        ms.sendNative{value: 1_000 ether}(r, _amounts(51, 1));
    }

    function test_nativeCap_onlyDecreases() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(ms));
        emit MaxNativeChargeLowered(MAX_NATIVE, 0.02 ether);
        ms.lowerMaxNativeCharge(0.02 ether);
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.MaxNativeChargeCanOnlyDecrease.selector, 0.02 ether, 1 ether));
        ms.lowerMaxNativeCharge(1 ether);
        vm.stopPrank();
        assertEq(ms.feeFor(20), FEE_20, "0.01 ETH: under the cap");
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.NativeChargeAboveCap.selector, FEE_MAX, 0.02 ether));
        ms.feeFor(500);
    }

    // ------------------------------------------------------------ quote + pay-up-to

    function test_quote_returnsEverythingTheDappNeeds() public view {
        (uint256 feeNative, uint256 feeUsd, uint256 price, uint256 updatedAt) = ms.quote(20);
        assertEq(feeNative, FEE_20);
        assertEq(feeUsd, U20);
        assertEq(price, ETH_USD);
        assertEq(updatedAt, block.timestamp);
    }

    function test_quote_freeTierIsAllZerosEvenWithBrokenFeed() public {
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(0, U20, U50, UMAX));
        feed.set(0, 0);
        (uint256 a, uint256 b, uint256 c, uint256 d) = ms.quote(5);
        assertEq(a + b + c + d, 0);
    }

    function test_quote_revertsAbove500() public {
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.TooManyRecipients.selector, 501, 500));
        ms.quote(501);
    }

    function test_payUpTo_coinMovesWithinBufferIsRefunded() public {
        address[] memory r = _recipients(10);
        uint256 sent = 10 ether + FEE_20 * 102 / 100; // dapp: total + quote + 2%
        feed.set(1980e8, block.timestamp); // ETH -1% between quote and send
        uint256 fee = ms.feeFor(10);
        assertGt(fee, FEE_20);
        vm.prank(alice);
        ms.sendNative{value: sent}(r, _amounts(10, 1 ether));
        assertEq(treasury.balance, fee);
        assertEq(alice.balance, 1_000 ether - 10 ether - fee, "paid the live fee, rest refunded");
    }

    function test_payUpTo_refundFailureRevertsEverything() public {
        RejectingReceiver rej = new RejectingReceiver();
        vm.deal(address(rej), 10 ether);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.expectRevert(MultisendCore.RefundFailed.selector);
        vm.prank(address(rej));
        ms.sendNative{value: 1 ether + FEE + 1}(r, a);
        assertEq(r[0].balance, 0, "nobody paid");
        // exact value needs no refund: works for a wallet that rejects coins
        vm.prank(address(rej));
        ms.sendNative{value: 1 ether + FEE}(r, a);
        assertEq(r[0].balance, 1 ether);
    }

    function test_payUpTo_refundCannotReenter() public {
        ReentrantReceiver evil = new ReentrantReceiver(address(ms));
        vm.deal(address(evil), 10 ether);
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        // The refund calls back into the sender; its re-entry attempt must fail and bubble up as RefundFailed.
        vm.expectRevert(MultisendCore.RefundFailed.selector);
        vm.prank(address(evil));
        ms.sendNative{value: 1 ether + FEE + 1}(r, a);
    }

    // ------------------------------------------------------------ treasury: fees forwarded in the same transaction

    function test_treasury_startsAsOwner() public {
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(address(0), owner);
        BulmoMultisend fresh = new BulmoMultisend(owner, MAX_FEE_USD, MAX_NATIVE, _caps(), _fees(0, 0, 0, 0));
        assertEq(fresh.treasury(), owner);
    }

    function test_treasury_receivesFeeInSameTx_nativeAndToken() public {
        address[] memory r = _recipients(10);
        vm.prank(alice);
        ms.sendNative{value: 10 ether + 1 ether}(r, _amounts(10, 1 ether)); // overpays 1 ETH - fee
        assertEq(treasury.balance, FEE_20, "fee forwarded");
        assertEq(address(ms).balance, 0, "contract holds nothing");

        vm.startPrank(alice);
        usdc.approve(address(ms), 10e6);
        ms.sendToken{value: 1 ether}(usdc, r, _amounts(10, 1e6));
        vm.stopPrank();
        assertEq(treasury.balance, 2 * FEE_20);
        assertEq(address(ms).balance, 0);
        assertEq(alice.balance, 1_000 ether - 10 ether - 2 * FEE_20, "all overpayment refunded");
    }

    function test_treasury_freeSendDoesNotTouchTreasury() public {
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(0, U20, U50, UMAX));
        RejectingReceiver rej = new RejectingReceiver();
        vm.prank(owner);
        ms.setTreasury(address(rej)); // even a broken treasury can't block free sends
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.prank(alice);
        ms.sendNative{value: 1 ether}(r, a);
        assertEq(r[0].balance, 1 ether);
    }

    function test_treasury_rejectingTreasuryRevertsPaidSendEntirely() public {
        RejectingReceiver rej = new RejectingReceiver();
        vm.prank(owner);
        ms.setTreasury(address(rej));
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.FeeTransferFailed.selector, address(rej)));
        vm.prank(alice);
        ms.sendNative{value: 1 ether + FEE}(r, a);
        assertEq(r[0].balance, 0, "nobody paid, nothing kept");
        assertEq(alice.balance, 1_000 ether);
    }

    function test_treasury_reentrantTreasuryCannotReenter() public {
        ReentrantReceiver evil = new ReentrantReceiver(address(ms));
        vm.prank(owner);
        ms.setTreasury(address(evil));
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.FeeTransferFailed.selector, address(evil)));
        vm.prank(alice);
        ms.sendNative{value: 1 ether + FEE}(r, a);
    }

    function test_treasury_contractWalletLikeSafeWorks() public {
        AcceptingReceiver safe = new AcceptingReceiver();
        vm.prank(owner);
        ms.setTreasury(address(safe));
        (address[] memory r, uint256[] memory a) = _one(makeAddr("bob"), 1 ether);
        vm.prank(alice);
        ms.sendNative{value: 1 ether + FEE}(r, a);
        assertEq(address(safe).balance, FEE);
    }

    function test_setTreasury_guardsAndEvent() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, false, false, address(ms));
        emit TreasuryUpdated(treasury, next);
        vm.prank(owner);
        ms.setTreasury(next);
        assertEq(ms.treasury(), next);

        vm.startPrank(owner);
        vm.expectRevert(BulmoMultisend.InvalidTreasury.selector);
        ms.setTreasury(address(0));
        vm.expectRevert(BulmoMultisend.InvalidTreasury.selector);
        ms.setTreasury(address(ms));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.setTreasury(alice);
    }

    // ------------------------------------------------------------ sweep (coins forced into the contract)

    function test_sweep_recoversForcedCoins() public {
        vm.deal(address(ms), 3 ether); // e.g. selfdestruct to the contract
        vm.expectEmit(true, false, false, true, address(ms));
        emit Swept(treasury, 3 ether);
        vm.prank(owner);
        ms.sweep(payable(treasury));
        assertEq(treasury.balance, 3 ether);
        assertEq(address(ms).balance, 0);
    }

    function test_sweep_guards() public {
        vm.expectRevert(BulmoMultisend.NothingToSweep.selector);
        vm.prank(owner);
        ms.sweep(payable(treasury));

        vm.deal(address(ms), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.sweep(payable(alice));
        vm.expectRevert(BulmoMultisend.ZeroAddress.selector);
        vm.prank(owner);
        ms.sweep(payable(address(0)));
        address rejecting = address(new RejectingReceiver());
        vm.expectRevert(BulmoMultisend.SweepFailed.selector);
        vm.prank(owner);
        ms.sweep(payable(rejecting));
        assertEq(address(ms).balance, 1 ether);
    }

    // ------------------------------------------------------------ rescue

    function test_rescueTokens_returnsStrayTransfers() public {
        vm.prank(alice);
        usdc.transfer(address(ms), 42e6); // someone sends tokens to the contract by mistake
        vm.expectEmit(true, true, false, true, address(ms));
        emit TokensRescued(address(usdc), alice, 42e6);
        vm.prank(owner);
        ms.rescueTokens(usdc, alice);
        assertEq(usdc.balanceOf(address(ms)), 0);
    }

    function test_rescueTokens_onlyOwnerAndNotToZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.rescueTokens(usdc, alice);
        vm.expectRevert(BulmoMultisend.ZeroAddress.selector);
        vm.prank(owner);
        ms.rescueTokens(usdc, address(0));
    }

    // ------------------------------------------------------------ ownership

    function test_renounceOwnership_isDisabled() public {
        vm.expectRevert(BulmoMultisend.RenounceDisabled.selector);
        vm.prank(owner);
        ms.renounceOwnership();
        assertEq(ms.owner(), owner);
    }

    function test_renounceOwnership_onlyOwnerEvenToRevert() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.renounceOwnership();
    }

    function test_ownership_isTwoStep() public {
        address newOwner = makeAddr("multisig");
        vm.prank(owner);
        ms.transferOwnership(newOwner);
        assertEq(ms.owner(), owner, "not transferred until accepted");
        assertEq(ms.pendingOwner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        ms.acceptOwnership();

        vm.prank(newOwner);
        ms.acceptOwnership();
        assertEq(ms.owner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        ms.setTiers(_caps(), _fees(0, 0, 0, 0));
    }

    // ------------------------------------------------------------ gas reference (forge snapshot)

    function test_gas_native_250() public {
        address[] memory r = _recipients(250);
        vm.prank(alice);
        ms.sendNative{value: 250 * 0.01 ether + FEE_MAX}(r, _amounts(250, 0.01 ether));
    }

    function test_gas_token_250() public {
        address[] memory r = _recipients(250);
        vm.startPrank(alice);
        usdc.approve(address(ms), 250 * 10e6);
        ms.sendToken{value: FEE_MAX}(usdc, r, _amounts(250, 10e6));
        vm.stopPrank();
    }
}
