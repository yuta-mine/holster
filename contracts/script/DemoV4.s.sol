// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HolsterHook} from "../src/HolsterHook.sol";
import {DemoRouter} from "./DemoRouter.sol";
import {DemoToken} from "./DemoToken.sol";

/// @notice Pump and dump against a deployed Holster hook (reads deployments/v4-<chainid>.json). If the band-off
///         pool from DeployV4 exists (deployments/v4-baseline-<chainid>.json), it gets the same moves.
///   STEP=pump   buys BASE until the price is ~1.15
///   STEP=dump   sells BASE back to 1.00; the hook checks the band first
///   STEP=poke   re-places the positions if needsPoke()
///   STEP=reset  starts the demo over (owner only): withdraw, move the price back to 1.00, deposit
///               10,000 BASE + 10,000 USDC again. Wait for the TWAP (30 min) before the next pump.
///   forge script script/DemoV4.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
contract DemoV4 is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant DEPOSIT = 10_000e18;

    function run() external {
        string memory json = vm.readFile(string.concat("deployments/v4-", vm.toString(block.chainid), ".json"));
        DemoRouter router = DemoRouter(vm.parseJsonAddress(json, ".router"));
        HolsterHook hook = HolsterHook(vm.parseJsonAddress(json, ".hook"));
        string memory baselineFile = string.concat("deployments/v4-baseline-", vm.toString(block.chainid), ".json");
        HolsterHook baseline = vm.exists(baselineFile)
            ? HolsterHook(vm.parseJsonAddress(vm.readFile(baselineFile), ".hook"))
            : HolsterHook(address(0));
        if (address(baseline).code.length == 0) baseline = HolsterHook(address(0));
        string memory step = vm.envOr("STEP", string("pump"));

        vm.startBroadcast();
        _step(step, hook, router);
        if (address(baseline) != address(0)) _step(step, baseline, router);
        vm.stopBroadcast();

        _print("Holster", hook);
        if (address(baseline) != address(0)) _print("Re-centering LP (band off)", baseline);
    }

    function _step(string memory step, HolsterHook hook, DemoRouter router) internal {
        PoolKey memory key = _key(hook);
        if (_eq(step, "pump")) {
            router.swap(key, false, -1e30, TickMath.getSqrtPriceAtTick(1398)); // ~1.15
        } else if (_eq(step, "dump")) {
            router.swap(key, true, -1e30, TickMath.getSqrtPriceAtTick(0)); // back to 1.00
        } else if (_eq(step, "poke")) {
            hook.poke();
        } else if (_eq(step, "reset")) {
            hook.withdraw();
            (uint160 sqrtP,,,) = hook.poolManager().getSlot0(key.toId());
            uint160 one = TickMath.getSqrtPriceAtTick(0);
            if (sqrtP != one) router.swap(key, sqrtP > one, -1e30, one); // only other LPs' liquidity is left
            DemoToken base = DemoToken(Currency.unwrap(key.currency0));
            DemoToken quote = DemoToken(Currency.unwrap(key.currency1));
            (, address me,) = vm.readCallers();
            if (base.balanceOf(me) < DEPOSIT) base.mint(me, DEPOSIT);
            if (quote.balanceOf(me) < DEPOSIT) quote.mint(me, DEPOSIT);
            base.approve(address(hook), DEPOSIT);
            quote.approve(address(hook), DEPOSIT);
            hook.deposit(DEPOSIT, DEPOSIT);
        }
    }

    function _key(HolsterHook hook) internal view returns (PoolKey memory key) {
        (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) = hook.poolKey();
    }

    function _print(string memory name, HolsterHook hook) internal view {
        (bool bidOk, bool askOk, uint256 price, uint256 twap) = hook.bandState();
        console.log(name);
        console.log("  price x1000 %d, TWAP x1000 %d", price / 1e15, twap / 1e15);
        console.log("  band allows bid %s, ask %s", bidOk ? "yes" : "NO", askOk ? "yes" : "NO");
        console.log("  hook bid on %s, ask on %s", hook.bidOn() ? "yes" : "no", hook.askOn() ? "yes" : "no");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
