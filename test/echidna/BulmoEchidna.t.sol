// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BulmoEchidna} from "./BulmoEchidna.sol";

/// Runs the Echidna/Medusa harness once in Foundry, so a broken harness fails `forge test` too.
contract BulmoEchidnaSmokeTest is Test {
    BulmoEchidna internal h;

    function setUp() public {
        h = new BulmoEchidna{value: 1_000 ether}();
    }

    function test_harness_everyActionKeepsTheInvariants() public {
        h.checkInvariants();
        h.sendNative(1, 3, 0);
        h.sendNative(2, 12, 1 ether);
        h.sendToken(3, 40, 5);
        h.sendNativeUnderfunded(4, 30, 7);
        h.sendTokenUnderfunded(5, 10);
        h.buyPersonal(bytes32(uint256(1)), 3);
        h.personalSendNative(6, 25, 9);
        h.movePrice(12345e8);
        h.setTiers(7, 3);
        h.changeMaxFee(8, false);
        h.changeMaxFee(8, true);
        h.changeNativeCap(9, false);
        h.changeNativeCap(9, true);
        h.changeFactoryPrice(10, 0);
        h.changeFactoryPrice(10, 1);
        h.changeFactoryPrice(10, 2);
        for (uint8 w; w < 16; ++w) {
            h.strangerAttacks(w, 1);
        }
        h.strangerUsesPersonal(11, 4);
        h.sendNative(12, 55, 0);
        h.checkInvariants();
    }
}
