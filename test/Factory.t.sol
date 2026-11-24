// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BulmoMultisendFactory} from "../src/BulmoMultisendFactory.sol";
import {BulmoPersonalMultisend} from "../src/BulmoPersonalMultisend.sol";
import {MultisendCore} from "../src/MultisendCore.sol";
import {UsdPricing} from "../src/UsdPricing.sol";
import {MockAggregator} from "./mocks/MockFeeds.sol";
import {MockToken, NoReturnToken, ReentrantToken} from "./mocks/Tokens.sol";
import {RejectingReceiver} from "./mocks/Receivers.sol";

contract FactoryTest is Test {
    BulmoMultisendFactory factory;
    MockToken usdc;
    MockAggregator feed;

    address bulmo = makeAddr("bulmo"); // factory owner
    address buyer = makeAddr("buyer");
    address teammate = makeAddr("teammate");
    address stranger = makeAddr("stranger");

    uint256 constant ETH_USD = 3000e8;
    uint256 constant MAX_PRICE_USD = 100e8;
    uint256 constant PRICE_USD = 49e8;
    uint256 constant MAX_NATIVE = 10 ether;
    uint256 constant PRICE = (PRICE_USD * 1e18 + ETH_USD - 1) / ETH_USD; // $49 at $3,000/ETH, rounded up

    event PersonalMultisendCreated(address indexed buyer, address indexed multisend, bytes32 salt, uint256 pricePaid);
    event PriceUsdUpdated(uint256 previousPriceUsd, uint256 newPriceUsd);
    event MaxPriceUsdLowered(uint256 previousMaxPriceUsd, uint256 newMaxPriceUsd);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event Swept(address indexed to, uint256 amount);
    event OperatorSet(address indexed operator, bool allowed);
    event NativeMultisent(address indexed sender, uint256 recipients, uint256 total, uint256 fee);
    event TokenMultisent(address indexed sender, address indexed token, uint256 recipients, uint256 total, uint256 fee);

    function setUp() public {
        vm.warp(1_700_000_000);
        factory = new BulmoMultisendFactory(bulmo, MAX_PRICE_USD, PRICE_USD, MAX_NATIVE);
        feed = new MockAggregator(8, int256(ETH_USD));
        vm.prank(bulmo);
        factory.setPriceSource(address(feed), address(0), 1 hours);
        usdc = new MockToken("USD Coin", "USDC", 6);
        vm.deal(buyer, 100 ether);
        vm.deal(teammate, 100 ether);
        vm.deal(stranger, 100 ether);
        usdc.mint(buyer, 1_000_000e6);
        usdc.mint(teammate, 1_000_000e6);
        usdc.mint(stranger, 1_000_000e6);
    }

    // ------------------------------------------------------------ helpers

    function _buy(address who, bytes32 salt) internal returns (BulmoPersonalMultisend p) {
        vm.prank(who);
        p = BulmoPersonalMultisend(factory.createPersonalMultisend{value: PRICE}(salt));
    }

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

    // ------------------------------------------------------------ factory: deployment

    function test_factory_deploysLockedImplementation() public {
        assertEq(factory.owner(), bulmo);
        assertEq(factory.priceUsd(), PRICE_USD);
        assertEq(factory.maxPriceUsd(), MAX_PRICE_USD);
        assertEq(factory.maxNativeCharge(), MAX_NATIVE);
        assertEq(factory.currentPrice(), PRICE);
        assertTrue(factory.implementation().code.length > 0);
        // the implementation itself can't be taken over
        BulmoPersonalMultisend impl = BulmoPersonalMultisend(factory.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(stranger);
        assertEq(impl.owner(), address(0));
    }

    function test_factory_constructorRejectsPriceAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisendFactory.PriceAboveMax.selector, 2, 1));
        new BulmoMultisendFactory(bulmo, 1, 2, MAX_NATIVE);
    }

    // ------------------------------------------------------------ factory: buying

    function test_buy_createsOwnedContractAtPredictedAddress() public {
        bytes32 salt = keccak256("main");
        address predicted = factory.predictAddress(buyer, salt);
        vm.expectEmit(true, true, false, true, address(factory));
        emit PersonalMultisendCreated(buyer, predicted, salt, PRICE);
        BulmoPersonalMultisend p = _buy(buyer, salt);

        assertEq(address(p), predicted);
        assertEq(p.owner(), buyer);
        assertEq(p.factory(), address(factory));
        assertTrue(factory.isPersonalMultisend(address(p)));
        assertEq(factory.totalCreated(), 1);
        assertEq(factory.createdBy(buyer)[0], address(p));
        assertEq(bulmo.balance, PRICE);
    }

    function test_buy_revertsBelowPrice() public {
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisendFactory.InsufficientValue.selector, PRICE, PRICE - 1));
        vm.prank(buyer);
        factory.createPersonalMultisend{value: PRICE - 1}(bytes32(0));
    }

    function test_buy_refundsOverpayment() public {
        uint256 before = buyer.balance;
        vm.prank(buyer);
        factory.createPersonalMultisend{value: 1 ether}(bytes32(0));
        assertEq(bulmo.balance, PRICE, "only the price stays");
        assertEq(buyer.balance, before - PRICE, "excess refunded");
    }

    function test_buy_refundFailureRevertsWholePurchase() public {
        RejectingReceiver rej = new RejectingReceiver();
        vm.deal(address(rej), 1 ether);
        vm.expectRevert(BulmoMultisendFactory.RefundFailed.selector);
        vm.prank(address(rej));
        factory.createPersonalMultisend{value: PRICE + 1}(bytes32(0));
        assertEq(factory.totalCreated(), 0);
        // Paying the exact price needs no refund, so a contract that rejects coins can still buy.
        vm.prank(address(rej));
        factory.createPersonalMultisend{value: PRICE}(bytes32(0));
        assertEq(factory.totalCreated(), 1);
    }

    function test_buy_revertsIfPriceRaisedAboveWhatWasSent() public {
        vm.prank(bulmo);
        factory.setPriceUsd(PRICE_USD * 2);
        uint256 newPrice = factory.currentPrice();
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisendFactory.InsufficientValue.selector, newPrice, PRICE));
        vm.prank(buyer);
        factory.createPersonalMultisend{value: PRICE}(bytes32(0));
    }

    function test_buy_coinPriceRiseWithinBufferIsRefunded() public {
        uint256 sent = PRICE * 102 / 100; // dapp adds a 2% buffer
        feed.set(int256(ETH_USD * 101 / 100), block.timestamp); // ETH up 1%: purchase gets cheaper in ETH
        uint256 charge = factory.currentPrice();
        assertLt(charge, PRICE);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        factory.createPersonalMultisend{value: sent}(bytes32(0));
        assertEq(buyer.balance, before - charge);
        // ETH down 1%: charge rises but the buffer still covers it.
        feed.set(int256(ETH_USD * 99 / 100), block.timestamp);
        charge = factory.currentPrice();
        assertGt(charge, PRICE);
        before = buyer.balance;
        vm.prank(buyer);
        factory.createPersonalMultisend{value: sent}(bytes32(uint256(1)));
        assertEq(buyer.balance, before - charge);
    }

    // ------------------------------------------------------------ factory: oracle + quote

    function test_quotePrice_matchesCharge() public view {
        (uint256 priceNative, uint256 usd, uint256 price, uint256 updatedAt) = factory.quotePrice();
        assertEq(priceNative, PRICE);
        assertEq(usd, PRICE_USD);
        assertEq(price, ETH_USD);
        assertEq(updatedAt, block.timestamp);
    }

    function test_quotePrice_zeroWhenFree() public {
        vm.prank(bulmo);
        factory.setPriceUsd(0);
        feed.set(0, 0); // oracle broken: free purchases don't care
        (uint256 a, uint256 b, uint256 c, uint256 d) = factory.quotePrice();
        assertEq(a + b + c + d, 0);
        vm.prank(buyer);
        factory.createPersonalMultisend(bytes32(0));
    }

    function test_buy_revertsOnStaleOrBrokenFeed() public {
        uint256 updated = block.timestamp - 1 hours - 1;
        feed.set(int256(ETH_USD), updated);
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.StalePrice.selector, updated, 1 hours));
        vm.prank(buyer);
        factory.createPersonalMultisend{value: 1 ether}(bytes32(0));

        feed.set(-1, block.timestamp);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        vm.prank(buyer);
        factory.createPersonalMultisend{value: 1 ether}(bytes32(0));
    }

    function test_buy_nativeCapBlocksAbsurdCharge() public {
        feed.set(1e6, block.timestamp); // broken feed says ETH = $0.01: $49 would be 4,900 ETH
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.NativeChargeAboveCap.selector, 4_900 ether, MAX_NATIVE));
        vm.prank(buyer);
        factory.createPersonalMultisend{value: 100 ether}(bytes32(0));
    }

    function test_buy_manualPriceMode() public {
        vm.startPrank(bulmo);
        factory.setPriceSource(address(0), address(0), 0);
        vm.expectRevert(UsdPricing.PriceUnavailable.selector);
        factory.currentPrice();
        factory.setManualPrice(49e8); // coin = $49
        vm.stopPrank();
        assertEq(factory.currentPrice(), 1 ether);
        vm.prank(buyer);
        factory.createPersonalMultisend{value: 1 ether}(bytes32(0));
        assertEq(bulmo.balance, 1 ether);
    }

    function test_factory_pricingAdminOnlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setPriceSource(address(0), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setManualPrice(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.lowerMaxNativeCharge(0);
        vm.stopPrank();
        vm.startPrank(bulmo);
        factory.lowerMaxNativeCharge(1 ether);
        vm.expectRevert(abi.encodeWithSelector(UsdPricing.MaxNativeChargeCanOnlyDecrease.selector, 1 ether, 2 ether));
        factory.lowerMaxNativeCharge(2 ether);
        vm.stopPrank();
    }

    function test_buy_sameSaltTwiceReverts() public {
        _buy(buyer, bytes32(0));
        vm.expectRevert(Errors.FailedDeployment.selector);
        vm.prank(buyer);
        factory.createPersonalMultisend{value: PRICE}(bytes32(0));
    }

    function test_buy_moreThanOneWithDifferentSalts() public {
        BulmoPersonalMultisend a = _buy(buyer, bytes32(uint256(1)));
        BulmoPersonalMultisend b = _buy(buyer, bytes32(uint256(2)));
        assertTrue(address(a) != address(b));
        assertEq(factory.createdBy(buyer).length, 2);
        assertEq(factory.totalCreated(), 2);
    }

    function test_buy_nobodyCanTakeABuyersAddress() public {
        bytes32 salt = keccak256("main");
        address buyersAddress = factory.predictAddress(buyer, salt);
        BulmoPersonalMultisend s = _buy(stranger, salt); // same salt, different buyer
        assertTrue(address(s) != buyersAddress, "address depends on the buyer");
        BulmoPersonalMultisend p = _buy(buyer, salt);
        assertEq(address(p), buyersAddress);
        assertEq(p.owner(), buyer);
    }

    function test_buy_freeWhenPriceIsZero() public {
        vm.prank(bulmo);
        factory.setPriceUsd(0);
        vm.prank(buyer);
        address p = factory.createPersonalMultisend(bytes32(0));
        assertEq(BulmoPersonalMultisend(p).owner(), buyer);
    }

    function test_clone_initializeRejectsZeroOwner() public {
        // The factory always passes the buyer, but a hand-made clone must not be ownerless either.
        BulmoPersonalMultisend raw = BulmoPersonalMultisend(Clones.clone(factory.implementation()));
        vm.expectRevert(BulmoPersonalMultisend.ZeroAddress.selector);
        raw.initialize(address(0));
    }

    function test_clone_cannotBeReinitialized() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        p.initialize(stranger);
        assertEq(p.owner(), buyer);
    }

    function test_directNativeTransferToFactoryReverts() public {
        vm.prank(buyer);
        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------ factory: price administration

    function test_setPriceUsd_withinCapOnlyOwner() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit PriceUsdUpdated(PRICE_USD, MAX_PRICE_USD);
        vm.prank(bulmo);
        factory.setPriceUsd(MAX_PRICE_USD);
        assertEq(factory.priceUsd(), MAX_PRICE_USD);

        vm.expectRevert(
            abi.encodeWithSelector(BulmoMultisendFactory.PriceAboveMax.selector, MAX_PRICE_USD + 1, MAX_PRICE_USD)
        );
        vm.prank(bulmo);
        factory.setPriceUsd(MAX_PRICE_USD + 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.setPriceUsd(0);
    }

    function test_lowerMaxPriceUsd_onlyDownAndClamps() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit MaxPriceUsdLowered(MAX_PRICE_USD, 20e8);
        vm.expectEmit(false, false, false, true, address(factory));
        emit PriceUsdUpdated(PRICE_USD, 20e8);
        vm.prank(bulmo);
        factory.lowerMaxPriceUsd(20e8);
        assertEq(factory.priceUsd(), 20e8);

        vm.expectRevert(abi.encodeWithSelector(BulmoMultisendFactory.MaxPriceCanOnlyDecrease.selector, 20e8, 21e8));
        vm.prank(bulmo);
        factory.lowerMaxPriceUsd(21e8);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.lowerMaxPriceUsd(0);
    }

    function test_lowerMaxPriceUsd_keepsPriceIfBelow() public {
        vm.prank(bulmo);
        factory.lowerMaxPriceUsd(PRICE_USD * 2);
        assertEq(factory.priceUsd(), PRICE_USD);
    }

    function test_payment_goesToTreasuryInSameTx() public {
        assertEq(factory.treasury(), bulmo, "starts as the owner");
        _buy(buyer, bytes32(uint256(1)));
        _buy(stranger, bytes32(uint256(1)));
        assertEq(bulmo.balance, 2 * PRICE);
        assertEq(address(factory).balance, 0, "factory holds nothing");
    }

    function test_setTreasury_redirectsPayments() public {
        address safe = makeAddr("safe");
        vm.expectEmit(true, true, false, false, address(factory));
        emit TreasuryUpdated(bulmo, safe);
        vm.prank(bulmo);
        factory.setTreasury(safe);
        _buy(buyer, bytes32(0));
        assertEq(safe.balance, PRICE);
        assertEq(bulmo.balance, 0);

        vm.startPrank(bulmo);
        vm.expectRevert(BulmoMultisendFactory.InvalidTreasury.selector);
        factory.setTreasury(address(0));
        vm.expectRevert(BulmoMultisendFactory.InvalidTreasury.selector);
        factory.setTreasury(address(factory));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.setTreasury(stranger);
    }

    function test_rejectingTreasuryRevertsPurchaseButFreeStillWorks() public {
        address rej = address(new RejectingReceiver());
        vm.prank(bulmo);
        factory.setTreasury(rej);
        vm.expectRevert(abi.encodeWithSelector(BulmoMultisendFactory.PaymentTransferFailed.selector, rej));
        vm.prank(buyer);
        factory.createPersonalMultisend{value: PRICE}(bytes32(0));
        assertEq(factory.totalCreated(), 0);
        vm.prank(bulmo);
        factory.setPriceUsd(0);
        vm.prank(buyer);
        factory.createPersonalMultisend(bytes32(0));
        assertEq(factory.totalCreated(), 1);
    }

    function test_sweep_recoversForcedCoinsWithGuards() public {
        vm.expectRevert(BulmoMultisendFactory.NothingToSweep.selector);
        vm.prank(bulmo);
        factory.sweep(payable(bulmo));

        vm.deal(address(factory), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        factory.sweep(payable(stranger));
        vm.expectRevert(BulmoMultisendFactory.ZeroAddress.selector);
        vm.prank(bulmo);
        factory.sweep(payable(address(0)));
        address rejecting = address(new RejectingReceiver());
        vm.expectRevert(BulmoMultisendFactory.SweepFailed.selector);
        vm.prank(bulmo);
        factory.sweep(payable(rejecting));

        vm.expectEmit(true, false, false, true, address(factory));
        emit Swept(bulmo, 2 ether);
        vm.prank(bulmo);
        factory.sweep(payable(bulmo));
        assertEq(bulmo.balance, 2 ether);
    }

    function test_factory_renounceDisabled_ownershipTwoStep() public {
        vm.expectRevert(BulmoMultisendFactory.RenounceDisabled.selector);
        vm.prank(bulmo);
        factory.renounceOwnership();

        address safe = makeAddr("safe");
        vm.prank(bulmo);
        factory.transferOwnership(safe);
        assertEq(factory.owner(), bulmo);
        vm.prank(safe);
        factory.acceptOwnership();
        assertEq(factory.owner(), safe);
    }

    // ------------------------------------------------------------ personal: sending

    function test_personal_ownerSendsNativeWithNoFee() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(60); // the tier that costs $49 per send elsewhere
        vm.expectEmit(true, false, false, true, address(p));
        emit NativeMultisent(buyer, 60, 6 ether, 0);
        vm.prank(buyer);
        uint256 total = p.sendNative{value: 6 ether}(r, _amounts(60, 0.1 ether));
        assertEq(total, 6 ether);
        assertEq(r[59].balance, 0.1 ether);
        assertEq(address(p).balance, 0, "nothing stays in the personal contract");
    }

    function test_personal_ownerSendsTokenStraightFromWallet() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(3);
        vm.startPrank(buyer);
        usdc.approve(address(p), 300e6);
        vm.expectEmit(true, true, false, true, address(p));
        emit TokenMultisent(buyer, address(usdc), 3, 300e6, 0);
        p.sendToken(usdc, r, _amounts(3, 100e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(r[2]), 100e6);
        assertEq(usdc.balanceOf(address(p)), 0);
        assertEq(usdc.allowance(buyer, address(p)), 0);
    }

    function test_personal_exactValueRules() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(2);
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.IncorrectValue.selector, 2 ether, 2 ether + 1));
        p.sendNative{value: 2 ether + 1}(r, _amounts(2, 1 ether));
        usdc.approve(address(p), 2e6);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.IncorrectValue.selector, 0, 1));
        p.sendToken{value: 1}(usdc, r, _amounts(2, 1e6)); // no fee: coins sent with a token send are refused
        vm.stopPrank();
    }

    function test_personal_strangerCannotUseIt() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(2);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotAllowed.selector, stranger));
        p.sendNative{value: 2 ether}(r, _amounts(2, 1 ether));
        usdc.approve(address(p), 2e6);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotAllowed.selector, stranger));
        p.sendToken(usdc, r, _amounts(2, 1e6));
        vm.stopPrank();
    }

    function test_personal_cannotPullTokensFromOtherWallets() public {
        // Even an approved operator can only send from their OWN wallet, never from the owner's.
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.prank(buyer);
        p.setOperator(teammate, true);
        vm.prank(buyer);
        usdc.approve(address(p), type(uint256).max); // owner's big approval
        uint256 ownerBefore = usdc.balanceOf(buyer);

        address[] memory r = _recipients(1);
        vm.prank(teammate); // teammate has not approved
        vm.expectRevert();
        p.sendToken(usdc, r, _amounts(1, 1e6));
        assertEq(usdc.balanceOf(buyer), ownerBefore, "owner's tokens untouched");
    }

    function test_personal_validatesInputsLikeMain() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.startPrank(buyer);
        vm.expectRevert(MultisendCore.NoRecipients.selector);
        p.sendNative(new address[](0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.TooManyRecipients.selector, 501, 500));
        p.sendNative(new address[](501), new uint256[](501));
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.LengthMismatch.selector, 2, 1));
        p.sendNative{value: 1}(_recipients(2), _amounts(1, 1));
        address[] memory r = _recipients(2);
        r[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.ZeroAddressRecipient.selector, 1));
        p.sendNative{value: 2}(r, _amounts(2, 1));
        uint256[] memory a = _amounts(2, 1);
        a[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.ZeroAmount.selector, 0));
        p.sendNative{value: 1}(_recipients(2), a);
        vm.stopPrank();
    }

    function test_personal_allOrNothing() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(3);
        r[2] = address(new RejectingReceiver());
        uint256 before = buyer.balance;
        vm.expectRevert(abi.encodeWithSelector(MultisendCore.NativeTransferFailed.selector, 2, r[2]));
        vm.prank(buyer);
        p.sendNative{value: 3 ether}(r, _amounts(3, 1 ether));
        assertEq(r[0].balance, 0);
        assertEq(buyer.balance, before);
    }

    function test_personal_usdtStyleToken() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(buyer, 10e6);
        address[] memory r = _recipients(2);
        vm.startPrank(buyer);
        usdt.approve(address(p), 10e6);
        p.sendToken(IERC20(address(usdt)), r, _amounts(2, 5e6));
        vm.stopPrank();
        assertEq(usdt.balanceOf(r[1]), 5e6);
    }

    function test_personal_blocksReentrantToken() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        ReentrantToken evil = new ReentrantToken();
        evil.mint(buyer, 10e18);
        evil.setTarget(address(p));
        address[] memory r = _recipients(1);
        vm.startPrank(buyer);
        evil.approve(address(p), 1e18);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        p.sendToken(IERC20(address(evil)), r, _amounts(1, 1e18));
        vm.stopPrank();
    }

    function test_personal_directNativeTransferReverts() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.prank(buyer);
        (bool ok,) = address(p).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------ personal: team wallets

    function test_operators_canSendFromTheirOwnWallet() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.expectEmit(true, false, false, true, address(p));
        emit OperatorSet(teammate, true);
        vm.prank(buyer);
        p.setOperator(teammate, true);
        assertTrue(p.isOperator(teammate));
        assertEq(p.operatorCount(), 1);

        address[] memory r = _recipients(2);
        vm.prank(teammate);
        p.sendNative{value: 2 ether}(r, _amounts(2, 1 ether));
        assertEq(r[0].balance, 1 ether);

        vm.prank(buyer);
        p.setOperator(teammate, false);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotAllowed.selector, teammate));
        vm.prank(teammate);
        p.sendNative{value: 2 ether}(r, _amounts(2, 1 ether));
        assertEq(p.operatorCount(), 0);
    }

    function test_operators_maxFiveAndGuards() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.startPrank(buyer);
        for (uint256 i; i < 5; ++i) {
            p.setOperator(makeAddr(string.concat("op", vm.toString(i))), true);
        }
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.TooManyOperators.selector, 5));
        p.setOperator(makeAddr("op5"), true);

        vm.expectRevert(
            abi.encodeWithSelector(BulmoPersonalMultisend.OperatorUnchanged.selector, makeAddr("op0"), true)
        );
        p.setOperator(makeAddr("op0"), true);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.OperatorUnchanged.selector, stranger, false));
        p.setOperator(stranger, false);
        vm.expectRevert(BulmoPersonalMultisend.ZeroAddress.selector);
        p.setOperator(address(0), true);

        p.setOperator(makeAddr("op0"), false); // frees a slot
        p.setOperator(makeAddr("op5"), true);
        assertEq(p.operatorCount(), 5);
        vm.stopPrank();
    }

    function test_operators_cannotManage() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.prank(buyer);
        p.setOperator(teammate, true);
        vm.startPrank(teammate);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotOwner.selector, teammate));
        p.setOperator(stranger, true);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotOwner.selector, teammate));
        p.transferOwnership(teammate);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotOwner.selector, teammate));
        p.rescue(address(0), teammate);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ personal: ownership + rescue

    function test_personal_twoStepOwnership() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address newOwner = makeAddr("newOwner");
        vm.prank(buyer);
        p.transferOwnership(newOwner);
        assertEq(p.owner(), buyer);
        assertEq(p.pendingOwner(), newOwner);

        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotPendingOwner.selector, stranger));
        vm.prank(stranger);
        p.acceptOwnership();

        vm.prank(newOwner);
        p.acceptOwnership();
        assertEq(p.owner(), newOwner);
        assertEq(p.pendingOwner(), address(0));

        // old owner lost access
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotAllowed.selector, buyer));
        vm.prank(buyer);
        p.sendNative{value: 1}(_recipients(1), _amounts(1, 1));
    }

    function test_personal_cancelPendingTransfer() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.startPrank(buyer);
        p.transferOwnership(stranger);
        p.transferOwnership(address(0));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotPendingOwner.selector, stranger));
        vm.prank(stranger);
        p.acceptOwnership();
    }

    function test_personal_rescueTokensAndCoins() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.prank(stranger);
        usdc.transfer(address(p), 5e6); // mistake
        vm.deal(address(p), 1 ether); // e.g. forced via selfdestruct

        vm.startPrank(buyer);
        p.rescue(address(usdc), buyer);
        p.rescue(address(0), buyer);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(p)), 0);
        assertEq(address(p).balance, 0);

        vm.expectRevert(BulmoPersonalMultisend.ZeroAddress.selector);
        vm.prank(buyer);
        p.rescue(address(0), address(0));
        vm.deal(address(p), 1 ether);
        address rejecting = address(new RejectingReceiver());
        vm.expectRevert(BulmoPersonalMultisend.RescueFailed.selector);
        vm.prank(buyer);
        p.rescue(address(0), rejecting);
    }

    function test_personal_bulmoHasNoPowerOverIt() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(1);
        uint256[] memory a = _amounts(1, 1);
        vm.deal(bulmo, 1 ether);
        vm.startPrank(bulmo);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotAllowed.selector, bulmo));
        p.sendNative{value: 1}(r, a);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotOwner.selector, bulmo));
        p.setOperator(bulmo, true);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotOwner.selector, bulmo));
        p.rescue(address(0), bulmo);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ limits + price-change publicity

    function test_limits_personalConstants() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        assertEq(p.MAX_RECIPIENTS(), 500);
        assertEq(p.MAX_OPERATORS(), 5);
    }

    function test_personal_maxRecipients() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(500);
        vm.prank(buyer);
        p.sendNative{value: 500}(r, _amounts(500, 1));
        assertEq(r[499].balance, 1);
    }

    function test_factory_priceChangesAreAlwaysPublic() public {
        vm.recordLogs();
        vm.startPrank(bulmo);
        factory.setPriceUsd(0);
        factory.lowerMaxPriceUsd(PRICE_USD);
        factory.setPriceSource(address(0), address(0), 0);
        factory.setManualPrice(1e8);
        factory.lowerMaxNativeCharge(1 ether);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 5, "every pricing change emits an event");
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_buy_chargesQuoteAndRefundsRest(uint64 rawUsd, uint64 rawEth, uint256 sent) public {
        uint256 usd = bound(rawUsd, 0, MAX_PRICE_USD);
        uint256 ethUsd = bound(rawEth, 100e8, 100_000e8);
        vm.prank(bulmo);
        factory.setPriceUsd(usd);
        feed.set(int256(ethUsd), block.timestamp);
        uint256 p = factory.currentPrice();
        sent = bound(sent, 0, 2 ether);
        vm.deal(buyer, sent);
        vm.prank(buyer);
        if (sent < p) {
            vm.expectRevert(abi.encodeWithSelector(BulmoMultisendFactory.InsufficientValue.selector, p, sent));
            factory.createPersonalMultisend{value: sent}(bytes32(0));
        } else {
            address m = factory.createPersonalMultisend{value: sent}(bytes32(0));
            assertEq(BulmoPersonalMultisend(m).owner(), buyer);
            assertEq(bulmo.balance, p);
            assertEq(buyer.balance, sent - p);
        }
    }

    function testFuzz_predictMatchesCreate(address who, bytes32 salt) public {
        vm.assume(who != address(0) && who.code.length == 0);
        vm.deal(who, PRICE);
        address predicted = factory.predictAddress(who, salt);
        vm.prank(who);
        assertEq(factory.createPersonalMultisend{value: PRICE}(salt), predicted);
    }

    function testFuzz_personal_onlyOwnerOrOperatorSends(address caller) public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        vm.prank(buyer);
        p.setOperator(teammate, true);
        vm.assume(caller != buyer && caller != teammate);
        vm.deal(caller, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BulmoPersonalMultisend.NotAllowed.selector, caller));
        vm.prank(caller);
        p.sendNative{value: 1}(_recipients(1), _amounts(1, 1));
    }

    function testFuzz_personal_exactPayouts(uint8 rawN, uint256 seed) public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        uint256 n = bound(rawN, 1, 100);
        address[] memory r = new address[](n);
        uint256[] memory a = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            r[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) | (1 << 159)));
            a[i] = bound(uint256(keccak256(abi.encode(seed, i, 1))), 1, 1e30);
            total += a[i];
        }
        usdc.mint(buyer, total);
        vm.startPrank(buyer);
        usdc.approve(address(p), total);
        p.sendToken(usdc, r, a);
        vm.stopPrank();
        for (uint256 i; i < n; ++i) {
            assertEq(usdc.balanceOf(r[i]), a[i]);
        }
        assertEq(usdc.balanceOf(address(p)), 0);
    }

    // ------------------------------------------------------------ gas reference

    function test_gas_createPersonal() public {
        vm.prank(buyer);
        factory.createPersonalMultisend{value: PRICE}(bytes32(0));
    }

    function test_gas_personal_token_250() public {
        BulmoPersonalMultisend p = _buy(buyer, bytes32(0));
        address[] memory r = _recipients(250);
        vm.startPrank(buyer);
        usdc.approve(address(p), 250 * 10e6);
        p.sendToken(usdc, r, _amounts(250, 10e6));
        vm.stopPrank();
    }
}
