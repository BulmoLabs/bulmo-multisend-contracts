// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BulmoMultisendFactory} from "../../src/BulmoMultisendFactory.sol";
import {BulmoPersonalMultisend} from "../../src/BulmoPersonalMultisend.sol";
import {MockToken} from "../mocks/Tokens.sol";
import {MockAggregator} from "../mocks/MockFeeds.sol";
import {FactoryHandler} from "./FactoryHandler.sol";

contract FactoryInvariantTest is Test {
    BulmoMultisendFactory factory;
    MockToken token;
    FactoryHandler handler;
    address bulmo = makeAddr("bulmo");
    uint256 constant INITIAL_MAX = 100e8; // $100

    function setUp() public {
        vm.warp(1_700_000_000);
        factory = new BulmoMultisendFactory(bulmo, INITIAL_MAX, 49e8, 10 ether);
        MockAggregator feed = new MockAggregator(8, 3000e8);
        vm.prank(bulmo);
        factory.setPriceSource(address(feed), address(0), 1 hours);
        token = new MockToken("Token", "TKN", 18);
        handler = new FactoryHandler(factory, token, feed, bulmo);
        targetContract(address(handler));
    }

    /// Payments never stay in the factory: every purchase reached a treasury in the same transaction.
    function invariant_neverHoldsNativeAndTreasuryGotEverySale() public view {
        assertEq(address(factory).balance, 0);
        assertEq(bulmo.balance + handler.treasury().balance, handler.ghostCollected());
    }

    function invariant_priceNeverAboveCap() public view {
        assertLe(factory.priceUsd(), factory.maxPriceUsd());
    }

    function invariant_capOnlyDecreases() public view {
        assertEq(factory.maxPriceUsd(), handler.ghostLowestMaxPrice());
        assertLe(factory.maxPriceUsd(), INITIAL_MAX);
    }

    /// Every buyer got back exactly what they paid above the price, at every coin price.
    function invariant_refundsExact() public view {
        assertEq(handler.ghostBadRefunds(), 0);
    }

    /// Every purchase is counted, registered, and owned by its buyer.
    function invariant_everyPurchaseRegisteredAndOwned() public view {
        uint256 n = handler.createdCount();
        assertEq(factory.totalCreated(), n);
        for (uint256 i; i < n; ++i) {
            address m = handler.created(i);
            assertTrue(factory.isPersonalMultisend(m));
            assertEq(BulmoPersonalMultisend(m).owner(), handler.buyerOf(m));
            assertEq(BulmoPersonalMultisend(m).factory(), address(factory));
        }
    }

    /// Personal Multisends never keep tokens or coins, and every token sent arrived.
    function invariant_personalContractsHoldNothing() public view {
        uint256 n = handler.createdCount();
        for (uint256 i; i < n; ++i) {
            address m = handler.created(i);
            assertEq(token.balanceOf(m), 0);
            assertEq(m.balance, 0);
        }
        uint256 delivered;
        for (uint256 i; i < handler.payeeCount(); ++i) {
            delivered += token.balanceOf(handler.payeeAt(i));
        }
        assertEq(delivered, handler.ghostTokensDelivered());
    }

    /// The shared implementation stays locked forever.
    function invariant_implementationStaysLocked() public view {
        assertEq(BulmoPersonalMultisend(factory.implementation()).owner(), address(0));
    }
}
