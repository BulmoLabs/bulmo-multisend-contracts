// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BulmoMultisend} from "../../src/BulmoMultisend.sol";
import {BulmoMultisendFactory} from "../../src/BulmoMultisendFactory.sol";
import {BulmoPersonalMultisend} from "../../src/BulmoPersonalMultisend.sol";
import {MockToken} from "../mocks/Tokens.sol";
import {MockAggregator} from "../mocks/MockFeeds.sol";
import {AcceptingReceiver} from "../mocks/Receivers.sol";

/// An address with no rights. Every privileged call it makes must fail.
contract Stranger {
    function tryCall(address target, bytes calldata data) external payable returns (bool ok) {
        (ok,) = target.call{value: msg.value}(data);
    }

    receive() external payable {}
}

/// Property tests for Echidna and Medusa (assertion mode).
///
/// The fuzzer calls the public functions below in random order with random arguments, and moves time
/// and blocks forward between calls. This contract is the owner of everything it deploys, so it can also
/// change fees, caps and prices at random. Every function asserts what must be true after it runs, and
/// `checkInvariants` asserts the global properties. Any failing assert is reported with the call sequence.
///
/// Properties:
///  P1  A correctly funded send never fails, pays every recipient exactly and refunds the sender exactly.
///  P2  An underfunded send always reverts and moves nothing.
///  P3  The treasury receives exactly the fees and purchases charged, in the same transaction.
///  P4  The contracts never keep native coin or tokens.
///  P5  maxFeeUsd, maxNativeCharge and maxPriceUsd only go down; raising them always reverts.
///  P6  No tier fee is above maxFeeUsd; the factory price is never above maxPriceUsd.
///  P7  Nobody but the owner can change settings, move funds or take ownership.
///  P8  Only the owner or an operator can send through a Personal Multisend; it charges no fee.
///  P9  A Personal Multisend purchase charges exactly the quoted price and gives the clone to the buyer.
///  P10 Ownership never changes without the two-step transfer.
contract BulmoEchidna {
    BulmoMultisend internal ms;
    BulmoMultisendFactory internal factory;
    MockToken internal token;
    MockAggregator internal feed;
    AcceptingReceiver internal treasury;
    Stranger internal stranger;
    BulmoPersonalMultisend internal personal;

    uint256 internal constant POOL = 12;
    uint256 internal constant MAX_FEE_USD = 100e8;
    uint256 internal constant NATIVE_CAP = 10 ether;
    uint256 internal constant MAX_PRICE_USD = 100e8;

    uint256 internal lastMaxFee = MAX_FEE_USD;
    uint256 internal lastNativeCap = NATIVE_CAP;
    uint256 internal lastMaxPrice = MAX_PRICE_USD;

    uint256 internal ghostTreasury; // everything the treasury should have received
    uint256 internal ghostNativeOut; // native coin paid to the recipient pool
    uint256 internal ghostTokenOut; // tokens paid to the recipient pool

    constructor() payable {
        feed = new MockAggregator(8, 3000e8);
        treasury = new AcceptingReceiver();
        stranger = new Stranger();

        uint32[] memory m = new uint32[](4);
        uint256[] memory f = new uint256[](4);
        (m[0], m[1], m[2], m[3]) = (5, 20, 50, 500);
        (f[0], f[1], f[2], f[3]) = (0, 10e8, 19e8, 49e8);
        ms = new BulmoMultisend(address(this), MAX_FEE_USD, NATIVE_CAP, m, f);
        ms.setPriceSource(address(feed), address(0), 1 days);
        ms.setTreasury(address(treasury));

        factory = new BulmoMultisendFactory(address(this), MAX_PRICE_USD, 49e8, NATIVE_CAP);
        factory.setPriceSource(address(feed), address(0), 1 days);
        factory.setTreasury(address(treasury));

        token = new MockToken("Test USD", "TUSD", 6);
        token.mint(address(this), type(uint128).max);
        token.approve(address(ms), type(uint256).max);
    }

    receive() external payable {}

    // ---------------------------------------------------------------- helpers

    function _pool(uint256 i) internal pure returns (address) {
        return address(uint160(0x5EED0000 + i)); // clear of the fuzzer's sender addresses (0x10000, 0x20000, 0x30000)
    }

    /// 1 to 60 recipients from the pool (repeats allowed), spanning every fee tier.
    function _batch(uint256 seed, uint256 nRaw, uint256 maxEach)
        internal
        pure
        returns (address[] memory r, uint256[] memory a, uint256 total, uint256[POOL] memory expected)
    {
        uint256 n = 1 + (nRaw % 60);
        r = new address[](n);
        a = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 idx = uint256(keccak256(abi.encode(seed, i))) % POOL;
            r[i] = _pool(idx);
            a[i] = 1 + (uint256(keccak256(abi.encode(seed, i, 1))) % maxEach);
            total += a[i];
            expected[idx] += a[i];
        }
    }

    function _nativeBalances() internal view returns (uint256[POOL] memory b) {
        for (uint256 i; i < POOL; ++i) {
            b[i] = _pool(i).balance;
        }
    }

    function _tokenBalances() internal view returns (uint256[POOL] memory b) {
        for (uint256 i; i < POOL; ++i) {
            b[i] = token.balanceOf(_pool(i));
        }
    }

    // ---------------------------------------------------------------- user actions

    /// P1, P3: funded native send, with random overpayment.
    function sendNative(uint256 seed, uint8 nRaw, uint96 extraRaw) public {
        (address[] memory r, uint256[] memory a, uint256 total, uint256[POOL] memory exp) = _batch(seed, nRaw, 1e15);
        uint256 fee;
        try ms.feeFor(r.length) returns (uint256 f) {
            fee = f;
        } catch {
            return; // price stale or above cap: paid sends are paused, which is intended
        }
        uint256 value = total + fee + (uint256(extraRaw) % 1 ether);
        if (value > address(this).balance) return;

        uint256[POOL] memory before = _nativeBalances();
        uint256 meBefore = address(this).balance;
        uint256 treasuryBefore = address(treasury).balance;
        try ms.sendNative{value: value}(r, a) returns (uint256 t) {
            assert(t == total);
            assert(address(this).balance == meBefore - total - fee); // exact refund
            assert(address(treasury).balance == treasuryBefore + fee);
            uint256[POOL] memory afterB = _nativeBalances();
            for (uint256 i; i < POOL; ++i) {
                assert(afterB[i] - before[i] == exp[i]);
            }
            ghostTreasury += fee;
            ghostNativeOut += total;
        } catch {
            assert(false); // a correctly funded send must not fail
        }
    }

    /// P2: any shortfall reverts.
    function sendNativeUnderfunded(uint256 seed, uint8 nRaw, uint256 shortRaw) public {
        (address[] memory r, uint256[] memory a, uint256 total,) = _batch(seed, nRaw, 1e15);
        uint256 fee;
        try ms.feeFor(r.length) returns (uint256 f) {
            fee = f;
        } catch {
            return;
        }
        uint256 required = total + fee;
        uint256 value = required - 1 - (shortRaw % required);
        uint256 meBefore = address(this).balance;
        try ms.sendNative{value: value}(r, a) {
            assert(false);
        } catch {
            assert(address(this).balance == meBefore);
        }
    }

    /// P1, P3: funded token send, with random overpayment of the fee.
    function sendToken(uint256 seed, uint8 nRaw, uint96 extraRaw) public {
        (address[] memory r, uint256[] memory a, uint256 total, uint256[POOL] memory exp) = _batch(seed, nRaw, 1e12);
        uint256 fee;
        try ms.feeFor(r.length) returns (uint256 f) {
            fee = f;
        } catch {
            return;
        }
        uint256 value = fee + (uint256(extraRaw) % 1 ether);
        if (value > address(this).balance) return;

        uint256[POOL] memory before = _tokenBalances();
        uint256 meBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 treasuryBefore = address(treasury).balance;
        try ms.sendToken{value: value}(token, r, a) returns (uint256 t) {
            assert(t == total);
            assert(address(this).balance == meBefore - fee);
            assert(token.balanceOf(address(this)) == tokensBefore - total);
            assert(address(treasury).balance == treasuryBefore + fee);
            uint256[POOL] memory afterB = _tokenBalances();
            for (uint256 i; i < POOL; ++i) {
                assert(afterB[i] - before[i] == exp[i]);
            }
            ghostTreasury += fee;
            ghostTokenOut += total;
        } catch {
            assert(false);
        }
    }

    /// P2: a token send without the fee reverts and moves nothing.
    function sendTokenUnderfunded(uint256 seed, uint8 nRaw) public {
        (address[] memory r, uint256[] memory a,,) = _batch(seed, nRaw, 1e12);
        uint256 fee;
        try ms.feeFor(r.length) returns (uint256 f) {
            fee = f;
        } catch {
            return;
        }
        if (fee == 0) return;
        uint256 tokensBefore = token.balanceOf(address(this));
        try ms.sendToken{value: fee - 1}(token, r, a) {
            assert(false);
        } catch {
            assert(token.balanceOf(address(this)) == tokensBefore);
        }
    }

    /// P9: buying a Personal Multisend.
    function buyPersonal(bytes32 salt, uint96 extraRaw) public {
        if (factory.predictAddress(address(this), salt).code.length != 0) return; // salt already used
        uint256 price;
        try factory.currentPrice() returns (uint256 p) {
            price = p;
        } catch {
            return;
        }
        uint256 value = price + (uint256(extraRaw) % 1 ether);
        if (value > address(this).balance) return;
        uint256 meBefore = address(this).balance;
        uint256 treasuryBefore = address(treasury).balance;
        try factory.createPersonalMultisend{value: value}(salt) returns (address clone) {
            assert(address(this).balance == meBefore - price);
            assert(address(treasury).balance == treasuryBefore + price);
            assert(factory.isPersonalMultisend(clone));
            assert(BulmoPersonalMultisend(clone).owner() == address(this));
            assert(clone == factory.predictAddress(address(this), salt));
            ghostTreasury += price;
            personal = BulmoPersonalMultisend(clone);
        } catch {
            assert(false);
        }
    }

    /// P8: the owner sends through its Personal Multisend with no fee; any other value reverts.
    function personalSendNative(uint256 seed, uint8 nRaw, uint256 wrong) public {
        if (address(personal) == address(0)) return;
        (address[] memory r, uint256[] memory a, uint256 total, uint256[POOL] memory exp) = _batch(seed, nRaw, 1e15);
        if (total + 1 > address(this).balance) return;
        uint256 off = 1 + (wrong % total);
        try personal.sendNative{value: total + off}(r, a) {
            assert(false);
        } catch {}
        try personal.sendNative{value: total - off}(r, a) {
            assert(false);
        } catch {}

        uint256[POOL] memory before = _nativeBalances();
        uint256 meBefore = address(this).balance;
        try personal.sendNative{value: total}(r, a) returns (uint256 t) {
            assert(t == total);
            assert(address(this).balance == meBefore - total);
            uint256[POOL] memory afterB = _nativeBalances();
            for (uint256 i; i < POOL; ++i) {
                assert(afterB[i] - before[i] == exp[i]);
            }
            ghostNativeOut += total;
        } catch {
            assert(false);
        }
    }

    // ---------------------------------------------------------------- market and owner actions

    /// The coin price moves (and the feed is refreshed, so paid sends keep working).
    function movePrice(uint256 raw) public {
        int256 price = int256(1e6 + (raw % 100_000e8)); // $0.01 to $100,000
        feed.set(price, block.timestamp);
    }

    function setTiers(uint256 seed, uint8 countRaw) public {
        uint256 n = 1 + (countRaw % 5);
        uint32[] memory m = new uint32[](n);
        uint256[] memory f = new uint256[](n);
        uint32 prev;
        for (uint256 i; i < n; ++i) {
            uint32 step = uint32(1 + (uint256(keccak256(abi.encode(seed, i))) % 100));
            m[i] = i == n - 1 ? 500 : prev + step;
            if (m[i] > 500) m[i] = 500;
            prev = m[i];
            f[i] = uint256(keccak256(abi.encode(seed, i, 2))) % (MAX_FEE_USD * 2); // sometimes above the cap
        }
        try ms.setTiers(m, f) {
            (, uint256[] memory fees) = ms.tiers();
            for (uint256 i; i < fees.length; ++i) {
                assert(fees[i] <= ms.maxFeeUsd());
            }
        } catch {}
    }

    /// P5: lowering works; raising always reverts.
    function changeMaxFee(uint256 raw, bool raise) public {
        uint256 cur = ms.maxFeeUsd();
        if (raise) {
            try ms.lowerMaxFeeUsd(cur + 1 + (raw % 1e20)) {
                assert(false);
            } catch {}
        } else {
            ms.lowerMaxFeeUsd(cur / 2 + (raw % (cur / 2 + 1)));
            assert(ms.maxFeeUsd() <= cur);
        }
    }

    function changeNativeCap(uint256 raw, bool raise) public {
        uint256 cur = ms.maxNativeCharge();
        if (raise) {
            try ms.lowerMaxNativeCharge(cur + 1 + (raw % 1e30)) {
                assert(false);
            } catch {}
        } else {
            ms.lowerMaxNativeCharge(cur / 2 + (raw % (cur / 2 + 1)));
            assert(ms.maxNativeCharge() <= cur);
        }
    }

    function changeFactoryPrice(uint256 raw, uint8 mode) public {
        uint256 maxP = factory.maxPriceUsd();
        if (mode % 3 == 0) {
            try factory.setPriceUsd(maxP + 1 + (raw % 1e20)) {
                assert(false);
            } catch {}
        } else if (mode % 3 == 1) {
            factory.setPriceUsd(raw % (maxP + 1));
        } else {
            try factory.lowerMaxPriceUsd(maxP / 2 + (raw % (maxP / 2 + 1))) {} catch {}
            assert(factory.maxPriceUsd() <= maxP);
        }
    }

    // ---------------------------------------------------------------- attacks

    /// P7: a stranger tries every privileged function. All must fail.
    function strangerAttacks(uint8 which, uint256 x) public {
        address s = address(stranger);
        bytes memory data;
        address target = address(ms);
        uint8 w = which % 16;
        if (w == 0) data = abi.encodeCall(BulmoMultisend.setTreasury, (s));
        else if (w == 1) data = abi.encodeCall(BulmoMultisend.sweep, (payable(s)));
        else if (w == 2) data = abi.encodeCall(BulmoMultisend.rescueTokens, (token, s));
        else if (w == 3) data = abi.encodeCall(BulmoMultisend.lowerMaxFeeUsd, (x));
        else if (w == 4) data = abi.encodeCall(BulmoMultisend.setPriceSource, (s, address(0), 1));
        else if (w == 5) data = abi.encodeCall(BulmoMultisend.setManualPrice, (x));
        else if (w == 6) data = abi.encodeWithSignature("transferOwnership(address)", s);
        else if (w == 7) data = abi.encodeWithSignature("renounceOwnership()");
        else if (w == 8) data = abi.encodeCall(BulmoMultisend.lowerMaxNativeCharge, (x));
        else {
            target = address(factory);
            if (w == 9) data = abi.encodeCall(BulmoMultisendFactory.setPriceUsd, (x));
            else if (w == 10) data = abi.encodeCall(BulmoMultisendFactory.setTreasury, (s));
            else if (w == 11) data = abi.encodeCall(BulmoMultisendFactory.sweep, (payable(s)));
            else if (w == 12) data = abi.encodeWithSignature("transferOwnership(address)", s);
            else {
                if (address(personal) == address(0)) return;
                target = address(personal);
                if (w == 13) data = abi.encodeCall(BulmoPersonalMultisend.setOperator, (s, true));
                else if (w == 14) data = abi.encodeCall(BulmoPersonalMultisend.transferOwnership, (s));
                else data = abi.encodeCall(BulmoPersonalMultisend.rescue, (address(0), s));
            }
        }
        assert(!stranger.tryCall(target, data));
        if (w == 6) assert(ms.pendingOwner() != s);
    }

    /// P8: a stranger cannot send through someone else's Personal Multisend, even paying exactly.
    function strangerUsesPersonal(uint256 seed, uint8 nRaw) public {
        if (address(personal) == address(0)) return;
        (address[] memory r, uint256[] memory a, uint256 total,) = _batch(seed, nRaw, 1e9);
        if (total > address(this).balance) return;
        bool ok = stranger.tryCall{value: total}(address(personal), abi.encodeCall(BulmoPersonalMultisend.sendNative, (r, a)));
        assert(!ok);
    }

    // ---------------------------------------------------------------- global properties

    function checkInvariants() public {
        // P4
        assert(address(ms).balance == 0);
        assert(token.balanceOf(address(ms)) == 0);
        assert(address(factory).balance == 0);
        if (address(personal) != address(0)) {
            assert(address(personal).balance == 0);
            assert(token.balanceOf(address(personal)) == 0);
        }
        // P3 and P1 over the whole run
        assert(address(treasury).balance == ghostTreasury);
        uint256 nat;
        uint256 tok;
        for (uint256 i; i < POOL; ++i) {
            nat += _pool(i).balance;
            tok += token.balanceOf(_pool(i));
        }
        assert(nat == ghostNativeOut);
        assert(tok == ghostTokenOut);
        // P5
        uint256 mf = ms.maxFeeUsd();
        uint256 nc = ms.maxNativeCharge();
        uint256 mp = factory.maxPriceUsd();
        assert(mf <= lastMaxFee && nc <= lastNativeCap && mp <= lastMaxPrice);
        (lastMaxFee, lastNativeCap, lastMaxPrice) = (mf, nc, mp);
        // P6
        (, uint256[] memory fees) = ms.tiers();
        for (uint256 i; i < fees.length; ++i) {
            assert(fees[i] <= mf);
        }
        assert(factory.priceUsd() <= mp);
        // P10
        assert(ms.owner() == address(this));
        assert(factory.owner() == address(this));
        if (address(personal) != address(0)) assert(personal.owner() == address(this));
    }
}
