// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BulmoMultisend} from "../src/BulmoMultisend.sol";

/// @notice Deploys BulmoMultisend with CREATE2 so it gets the SAME address on every chain,
///         as long as the bytecode, salt and constructor arguments are identical.
///         Prices are in USD, so the real tier table ships at deploy. Paid tiers start working once
///         the chain's price source is set with SetPricing.s.sol (the free tier works immediately).
///
/// Env (identical on every chain):
///   OWNER                 owner address (use a multisig)
///   MAX_FEE_USD           optional, USD cap per send, 8 decimals. Default 100e8 ($100)
///   MAX_NATIVE_CHARGE     optional, cap on any single fee in native wei. Default 10e18; lower per chain after deploy
///   TIER_MAX_RECIPIENTS   optional, default "5,20,50,500"
///   TIER_FEES_USD         optional, 8 decimals, default "0,1000000000,1900000000,4900000000" ($0 / $10 / $19 / $49)
///   SALT                  optional bytes32, default keccak256("bulmo.multisend.v1")
///
/// Run (dry run first, then add --broadcast --verify):
///   forge script script/Deploy.s.sol --rpc-url base --account deployer
contract Deploy is Script {
    // CREATE2_FACTORY (Arachnid's deterministic deployment proxy, 0x4e59...956C) comes from forge-std's Base.

    function run() external returns (BulmoMultisend ms) {
        address owner = vm.envAddress("OWNER");
        uint256 maxFeeUsd = vm.envOr("MAX_FEE_USD", uint256(100e8));
        uint256 maxNative = vm.envOr("MAX_NATIVE_CHARGE", uint256(10 ether));
        bytes32 salt = vm.envOr("SALT", keccak256("bulmo.multisend.v1"));
        (uint32[] memory tierMax, uint256[] memory tierFees) = readTiers();

        require(owner != address(0), "OWNER not set");
        require(CREATE2_FACTORY.code.length > 0, "CREATE2 factory missing on this chain: deploy it first (see README)");

        bytes memory args = abi.encode(owner, maxFeeUsd, maxNative, tierMax, tierFees);
        bytes memory initCode = abi.encodePacked(type(BulmoMultisend).creationCode, args);
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        console2.log("Chain id:          ", block.chainid);
        console2.log("Predicted address: ", predicted);

        if (predicted.code.length > 0) {
            console2.log("Already deployed on this chain, nothing to do.");
            return BulmoMultisend(predicted);
        }

        vm.startBroadcast();
        ms = new BulmoMultisend{salt: salt}(owner, maxFeeUsd, maxNative, tierMax, tierFees);
        vm.stopBroadcast();

        require(address(ms) == predicted, "address mismatch");
        require(ms.owner() == owner && ms.maxFeeUsd() == maxFeeUsd && ms.maxNativeCharge() == maxNative, "bad state");
        require(ms.feeUsdFor(tierMax[tierMax.length - 1]) == tierFees[tierFees.length - 1], "bad tiers");
        console2.log("Deployed BulmoMultisend at", address(ms));
        console2.log("Next: set this chain's price source with script/SetPricing.s.sol");
    }

    /// Reads the tier table from env (comma separated), defaulting to Bulmo's pricing.
    function readTiers() internal view returns (uint32[] memory tierMax, uint256[] memory tierFees) {
        uint256[] memory defMax = new uint256[](4);
        (defMax[0], defMax[1], defMax[2], defMax[3]) = (5, 20, 50, 500);
        uint256[] memory defFees = new uint256[](4);
        (defFees[0], defFees[1], defFees[2], defFees[3]) = (0, 10e8, 19e8, 49e8);
        uint256[] memory rawMax = vm.envOr("TIER_MAX_RECIPIENTS", ",", defMax);
        tierFees = vm.envOr("TIER_FEES_USD", ",", defFees);
        require(rawMax.length == tierFees.length, "tier lists differ in length");
        tierMax = new uint32[](rawMax.length);
        for (uint256 i; i < rawMax.length; ++i) {
            require(rawMax[i] <= type(uint32).max, "tier size too large");
            // forge-lint: disable-next-line(unsafe-typecast)
            tierMax[i] = uint32(rawMax[i]);
        }
    }
}
