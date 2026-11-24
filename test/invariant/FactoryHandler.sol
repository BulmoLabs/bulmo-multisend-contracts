// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BulmoMultisendFactory} from "../../src/BulmoMultisendFactory.sol";
import {BulmoPersonalMultisend} from "../../src/BulmoPersonalMultisend.sol";
import {MockToken} from "../mocks/Tokens.sol";
import {MockAggregator} from "../mocks/MockFeeds.sol";

/// Random purchases, price changes, withdrawals and personal sends, with ghost accounting.
contract FactoryHandler is Test {
    BulmoMultisendFactory public factory;
    MockToken public token;
    MockAggregator public feed;
    address public bulmo;
    address public treasury = makeAddr("treasury");

    address[] internal buyers;
    address[] internal pool;
    address[] public created;
    mapping(address => address) public buyerOf;

    uint256 public ghostCollected;

    uint256 public ghostLowestMaxPrice;
    uint256 public ghostBadRefunds;
    uint256 public ghostTokensDelivered;
    uint256 public nonce;

    constructor(BulmoMultisendFactory _f, MockToken _t, MockAggregator _feed, address _bulmo) {
        factory = _f;
        token = _t;
        feed = _feed;
        bulmo = _bulmo;
        ghostLowestMaxPrice = _f.maxPriceUsd();
        for (uint256 i; i < 5; ++i) {
            buyers.push(makeAddr(string.concat("buyer", vm.toString(i))));
        }
        for (uint256 i; i < 10; ++i) {
            pool.push(makeAddr(string.concat("payee", vm.toString(i))));
        }
    }

    function buy(uint256 buyerSeed, uint64 extra) external {
        address b = buyers[buyerSeed % buyers.length];
        uint256 p = factory.currentPrice();
        vm.deal(b, p + extra);
        vm.prank(b);
        address m = factory.createPersonalMultisend{value: p + extra}(bytes32(nonce++)); // unique salt
        if (b.balance != extra) ghostBadRefunds++;
        created.push(m);
        buyerOf[m] = b;
        ghostCollected += p;
    }

    function movePrice(uint256 price) external {
        feed.set(int256(bound(price, 100e8, 100_000e8)), block.timestamp);
    }

    function personalSend(uint256 which, uint256 seed) external {
        if (created.length == 0) return;
        address m = created[which % created.length];
        address owner_ = buyerOf[m];
        uint256 n = bound(seed, 1, 8);
        address[] memory r = new address[](n);
        uint256[] memory a = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            r[i] = pool[uint256(keccak256(abi.encode(seed, i))) % pool.length];
            a[i] = bound(uint256(keccak256(abi.encode(seed, i, 1))), 1, 1e24);
            total += a[i];
        }
        token.mint(owner_, total);
        vm.startPrank(owner_);
        token.approve(m, total);
        BulmoPersonalMultisend(m).sendToken(token, r, a);
        vm.stopPrank();
        ghostTokensDelivered += total;
    }

    function setPriceUsd(uint256 p) external {
        p = bound(p, 0, factory.maxPriceUsd());
        vm.prank(bulmo);
        factory.setPriceUsd(p);
    }

    function lowerMaxPriceUsd(uint256 m) external {
        m = bound(m, 0, factory.maxPriceUsd());
        vm.prank(bulmo);
        factory.lowerMaxPriceUsd(m);
        if (m < ghostLowestMaxPrice) ghostLowestMaxPrice = m;
    }

    function switchTreasury(bool toOwner) external {
        vm.prank(bulmo);
        factory.setTreasury(toOwner ? bulmo : treasury);
    }

    function createdCount() external view returns (uint256) {
        return created.length;
    }

    function payeeCount() external view returns (uint256) {
        return pool.length;
    }

    function payeeAt(uint256 i) external view returns (address) {
        return pool[i];
    }
}
