// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HolsterHook} from "../src/HolsterHook.sol";
import {DemoRouter} from "./DemoRouter.sol";

/// @notice Pump and dump against a deployed Holster hook (reads deployments/v4-<chainid>.json).
///   STEP=pump  buys BASE until the price is ~1.15
///   STEP=dump  sells BASE back to 1.00; the hook checks the band first
///   STEP=poke  re-places the positions if needsPoke()
///   forge script script/DemoV4.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
contract DemoV4 is Script {
    function run() external {
        string memory json = vm.readFile(string.concat("deployments/v4-", vm.toString(block.chainid), ".json"));
        HolsterHook hook = HolsterHook(vm.parseJsonAddress(json, ".hook"));
        DemoRouter router = DemoRouter(vm.parseJsonAddress(json, ".router"));
        PoolKey memory key = PoolKey(
            Currency.wrap(vm.parseJsonAddress(json, ".base")),
            Currency.wrap(vm.parseJsonAddress(json, ".quote")),
            3000,
            10,
            IHooks(address(hook))
        );
        string memory step = vm.envOr("STEP", string("pump"));

        vm.startBroadcast();
        if (_eq(step, "pump")) {
            router.swap(key, false, -1e30, TickMath.getSqrtPriceAtTick(1398)); // ~1.15
        } else if (_eq(step, "dump")) {
            router.swap(key, true, -1e30, TickMath.getSqrtPriceAtTick(0)); // back to 1.00
        } else if (_eq(step, "poke")) {
            hook.poke();
        }
        vm.stopBroadcast();

        (bool bidOk, bool askOk, uint256 price, uint256 twap) = hook.bandState();
        console.log("price x1000 %d, TWAP x1000 %d", price / 1e15, twap / 1e15);
        console.log("band allows bid %s, ask %s", bidOk ? "yes" : "NO", askOk ? "yes" : "NO");
        console.log("hook bid on %s, ask on %s", hook.bidOn() ? "yes" : "no", hook.askOn() ? "yes" : "no");
        console.log("needsPoke %s", hook.needsPoke() ? "true" : "false");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
