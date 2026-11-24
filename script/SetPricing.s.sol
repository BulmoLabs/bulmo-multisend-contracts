// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BulmoMultisend} from "../src/BulmoMultisend.sol";
import {BulmoMultisendFactory} from "../src/BulmoMultisendFactory.sol";
import {UsdPricing} from "../src/UsdPricing.sol";

interface IFeedInfo {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Connects one chain's deployed contracts to its native/USD price, after checking the feed on-chain.
///         Run once per chain after Deploy + DeployFactory. Dollar prices are already set at deploy.
///
/// Known chains (feed, sequencer feed and max age built in, verified on-chain each run):
///   1 Ethereum, 56 BNB Chain, 8453 Base, 42161 Arbitrum, 999 HyperEVM, 4663 Robinhood Chain
/// Elysium has no oracle yet: pass MANUAL_PRICE. Any built-in value can be overridden from env.
///
/// Env:
///   MULTISEND / FACTORY      addresses to configure (either or both)
///   PRICE_FEED               override or provide the Chainlink native/USD feed
///   SEQUENCER_FEED           L2 sequencer uptime feed (optional)
///   MAX_PRICE_AGE            seconds; feed heartbeat plus a margin
///   FEED_DESCRIPTION         expected description(), e.g. "HYPE / USD" (checked when set or known)
///   MANUAL_PRICE             native/USD price with 8 decimals: switches to manual mode (no feed)
///   NEW_MAX_NATIVE_CHARGE    optional: lower the native cap (wei). Permanent: leave room for the coin falling
///   TREASURY                 optional: where fees go on this chain (default: the owner). Must accept native coin
///
/// Owner is an EOA:  forge script script/SetPricing.s.sol --rpc-url base --account owner --broadcast
/// Owner is a Safe:  add --sig "printCalldata()" and submit the printed calls in the Safe app.
contract SetPricing is Script {
    struct Source {
        address feed;
        address sequencer;
        uint32 maxAge;
        string description;
        uint256 manualPrice;
    }

    function run() external {
        Source memory s = _source();
        _check(s);
        uint256 newCap = vm.envOr("NEW_MAX_NATIVE_CHARGE", type(uint256).max);
        address treasury = vm.envOr("TREASURY", address(0));
        address[] memory targets = _targets();

        vm.startBroadcast();
        for (uint256 i; i < targets.length; ++i) {
            // Both contracts share the UsdPricing owner functions.
            BulmoMultisend t = BulmoMultisend(payable(targets[i]));
            t.setPriceSource(s.feed, s.sequencer, s.maxAge);
            if (s.feed == address(0)) t.setManualPrice(s.manualPrice);
            if (newCap < t.maxNativeCharge()) t.lowerMaxNativeCharge(newCap);
            if (treasury != address(0) && treasury != t.treasury()) t.setTreasury(treasury);
        }
        vm.stopBroadcast();

        _report();
    }

    /// For Safe owners: runs the same checks and prints the calls to submit, per target.
    function printCalldata() external view {
        Source memory s = _source();
        _check(s);
        uint256 newCap = vm.envOr("NEW_MAX_NATIVE_CHARGE", type(uint256).max);
        address[] memory targets = _targets();
        for (uint256 i; i < targets.length; ++i) {
            console2.log("to:", targets[i]);
            console2.logBytes(abi.encodeCall(BulmoMultisend.setPriceSource, (s.feed, s.sequencer, s.maxAge)));
            if (s.feed == address(0)) {
                console2.logBytes(abi.encodeCall(BulmoMultisend.setManualPrice, (s.manualPrice)));
            }
            if (newCap != type(uint256).max) {
                console2.logBytes(abi.encodeCall(BulmoMultisend.lowerMaxNativeCharge, (newCap)));
            }
            address treasury = vm.envOr("TREASURY", address(0));
            if (treasury != address(0)) console2.logBytes(abi.encodeCall(BulmoMultisend.setTreasury, (treasury)));
        }
    }

    // ---------------------------------------------------------------- source

    function _source() internal view returns (Source memory s) {
        s.manualPrice = vm.envOr("MANUAL_PRICE", uint256(0));
        if (s.manualPrice != 0) return s; // manual mode: no feed, no sequencer, no max age

        uint256 id = block.chainid;
        if (id == 1) {
            s = Source(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, address(0), 2 hours, "ETH / USD", 0);
        } else if (id == 56) {
            s = Source(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE, address(0), 2 hours, "BNB / USD", 0);
        } else if (id == 8453) {
            s = Source(
                0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70,
                0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
                2 hours,
                "ETH / USD",
                0
            );
        } else if (id == 42161) {
            // 24h heartbeat (0.05% deviation keeps it fresh in practice)
            s = Source(
                0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612,
                0xFdB631F5EE196F0ed6FAa767959853A9F217697D,
                25 hours,
                "ETH / USD",
                0
            );
        } else if (id == 999) {
            // HyperEVM is not a rollup: no sequencer feed. Deviation-driven, gaps of 2h+ seen: 24h heartbeat assumed.
            s = Source(0xa5a72eF19F82A579431186402425593a559ed352, address(0), 25 hours, "HYPE / USD", 0);
        } else if (id == 4663) {
            // Robinhood Chain (Arbitrum Orbit L2). Pass SEQUENCER_FEED once Chainlink lists its uptime feed.
            s = Source(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, address(0), 25 hours, "ETH / USD", 0);
        }

        s.feed = vm.envOr("PRICE_FEED", s.feed);
        s.sequencer = vm.envOr("SEQUENCER_FEED", s.sequencer);
        uint256 age = vm.envOr("MAX_PRICE_AGE", uint256(s.maxAge));
        require(age > 0 && age <= type(uint32).max, "set MAX_PRICE_AGE (feed heartbeat + margin)");
        // forge-lint: disable-next-line(unsafe-typecast)
        s.maxAge = uint32(age);
        s.description = vm.envOr("FEED_DESCRIPTION", s.description);
        require(s.feed != address(0), "no known feed for this chain: set PRICE_FEED, or MANUAL_PRICE");
    }

    function _check(Source memory s) internal view {
        console2.log("Chain id:", block.chainid);
        if (s.feed == address(0)) {
            console2.log("Manual price (8 decimals):", s.manualPrice);
            return;
        }
        require(s.feed.code.length > 0, "PRICE_FEED has no code");
        IFeedInfo feed = IFeedInfo(s.feed);
        string memory desc = feed.description();
        console2.log("Feed:", s.feed, desc);
        if (bytes(s.description).length != 0) {
            require(keccak256(bytes(desc)) == keccak256(bytes(s.description)), "feed description mismatch");
        }
        require(feed.decimals() <= 18, "feed decimals > 18");
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0, "feed answer <= 0");
        require(block.timestamp - updatedAt <= s.maxAge, "feed is older than MAX_PRICE_AGE right now");
        console2.log("Answer:", uint256(answer), "decimals:", feed.decimals());
        console2.log("Age (s):", block.timestamp - updatedAt, "max:", s.maxAge);

        if (s.sequencer != address(0)) {
            require(s.sequencer.code.length > 0, "SEQUENCER_FEED has no code");
            (, int256 status, uint256 upSince,,) = IFeedInfo(s.sequencer).latestRoundData();
            require(status == 0, "sequencer reports down");
            console2.log("Sequencer up since:", upSince);
        }
    }

    function _targets() internal view returns (address[] memory t) {
        address ms = vm.envOr("MULTISEND", address(0));
        address fac = vm.envOr("FACTORY", address(0));
        require(ms != address(0) || fac != address(0), "set MULTISEND and/or FACTORY");
        t = new address[]((ms != address(0) ? 1 : 0) + (fac != address(0) ? 1 : 0));
        uint256 i;
        if (ms != address(0)) t[i++] = ms;
        if (fac != address(0)) t[i] = fac;
    }

    // ---------------------------------------------------------------- report

    function _report() internal view {
        address msAddr = vm.envOr("MULTISEND", address(0));
        if (msAddr != address(0)) {
            BulmoMultisend ms = BulmoMultisend(payable(msAddr));
            console2.log("Multisend treasury:", ms.treasury());
            (uint32[] memory m,) = ms.tiers();
            for (uint256 i; i < m.length; ++i) {
                (uint256 feeNative, uint256 feeUsd,,) = ms.quote(m[i]);
                console2.log("up to", m[i], "recipients: fee USD(8)", feeUsd);
                console2.log("                 fee native wei", feeNative);
            }
            _suggestCap(UsdPricing(msAddr));
        }
        address facAddr = vm.envOr("FACTORY", address(0));
        if (facAddr != address(0)) {
            (uint256 priceNative, uint256 usd,,) = BulmoMultisendFactory(facAddr).quotePrice();
            console2.log("Personal Multisend: USD(8)", usd, "native wei", priceNative);
            console2.log("Factory treasury:", BulmoMultisendFactory(facAddr).treasury());
            _suggestCap(UsdPricing(facAddr));
        }
    }

    function _suggestCap(UsdPricing p) internal view {
        console2.log("Native cap (wei):", p.maxNativeCharge());
        (uint256 price,) = p.nativeUsdPrice();
        console2.log("  ~$300 at today's price would be:", 300e8 * 1e18 / price);
    }
}
