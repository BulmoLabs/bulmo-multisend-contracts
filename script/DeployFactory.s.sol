// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BulmoMultisendFactory} from "../src/BulmoMultisendFactory.sol";

/// @notice Deploys the Personal Multisend factory with CREATE2: same factory address on every chain,
///         so the same buyer + salt gets the same Personal Multisend address on every chain too.
///         Purchases work once the chain's price source is set with SetPricing.s.sol.
///
/// Env (identical on every chain):
///   OWNER                   owner (multisig)
///   FACTORY_MAX_PRICE_USD   optional, 8 decimals, default 100e8 ($100). Can only be lowered later
///   FACTORY_PRICE_USD       optional, 8 decimals, default 49e8 ($49)
///   MAX_NATIVE_CHARGE       optional, native wei cap per purchase, default 10e18; lower per chain after deploy
///   FACTORY_SALT            optional bytes32, default keccak256("bulmo.multisend.factory.v1")
contract DeployFactory is Script {
    function run() external returns (BulmoMultisendFactory f) {
        address owner = vm.envAddress("OWNER");
        uint256 maxPriceUsd = vm.envOr("FACTORY_MAX_PRICE_USD", uint256(100e8));
        uint256 priceUsd = vm.envOr("FACTORY_PRICE_USD", uint256(49e8));
        uint256 maxNative = vm.envOr("MAX_NATIVE_CHARGE", uint256(10 ether));
        bytes32 salt = vm.envOr("FACTORY_SALT", keccak256("bulmo.multisend.factory.v1"));
        require(owner != address(0), "OWNER not set");
        require(priceUsd <= maxPriceUsd, "FACTORY_PRICE_USD above FACTORY_MAX_PRICE_USD");
        require(CREATE2_FACTORY.code.length > 0, "CREATE2 factory missing on this chain");

        bytes memory initCode = abi.encodePacked(
            type(BulmoMultisendFactory).creationCode, abi.encode(owner, maxPriceUsd, priceUsd, maxNative)
        );
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        console2.log("Chain id:                  ", block.chainid);
        console2.log("Predicted factory address: ", predicted);
        if (predicted.code.length > 0) {
            console2.log("Already deployed on this chain, nothing to do.");
            return BulmoMultisendFactory(predicted);
        }

        vm.startBroadcast();
        f = new BulmoMultisendFactory{salt: salt}(owner, maxPriceUsd, priceUsd, maxNative);
        vm.stopBroadcast();

        require(address(f) == predicted, "address mismatch");
        require(f.owner() == owner && f.priceUsd() == priceUsd && f.maxPriceUsd() == maxPriceUsd, "bad state");
        require(f.maxNativeCharge() == maxNative, "bad cap");
        console2.log("Deployed factory at        ", address(f));
        console2.log("Implementation             ", f.implementation());
    }
}
