// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployV4} from "../script/DeployV4.s.sol";
import {DemoV4} from "../script/DemoV4.s.sol";
import {DemoToken} from "../script/DemoToken.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HolsterHook} from "../src/HolsterHook.sol";

/// Runs the deploy and demo scripts end to end on the test chain.
contract ScriptsTest is Test {
    function test_deployAndDemoV4() public {
        vm.warp(1_000_000 * 60);
        new DeployV4().run();
        string memory json = vm.readFile(string.concat("deployments/v4-", vm.toString(block.chainid), ".json"));
        HolsterHook hook = HolsterHook(vm.parseJsonAddress(json, ".hook"));
        assertTrue(hook.live());

        DemoV4 demo = new DemoV4();
        vm.setEnv("STEP", "pump");
        demo.run();
        vm.warp(1_000_000 * 60 + 12);
        vm.setEnv("STEP", "dump");
        demo.run();
        assertTrue(hook.needsPoke()); // back inside the band: both sides return on the next poke
        vm.setEnv("STEP", "poke");
        demo.run();
        assertTrue(hook.bidOn() && hook.askOn());
    }

    /// Holster and the band-off pool get the same pump and dump; the reset step starts both over.
    function test_baselineComparisonAndReset() public {
        vm.warp(1_000_000 * 60);
        new DeployV4().run();
        string memory json = vm.readFile(string.concat("deployments/v4-", vm.toString(block.chainid), ".json"));
        HolsterHook hook = HolsterHook(vm.parseJsonAddress(json, ".hook"));
        HolsterHook baseline = HolsterHook(
            vm.parseJsonAddress(vm.readFile(string.concat("deployments/v4-baseline-", vm.toString(block.chainid), ".json")), ".hook")
        );
        assertTrue(baseline.live());

        DemoV4 demo = new DemoV4();
        vm.setEnv("STEP", "pump");
        demo.run();
        vm.warp(1_000_000 * 60 + 12);
        vm.setEnv("STEP", "dump");
        demo.run();

        uint256 snap = vm.snapshotState();
        int256 holsterPnl = _withdrawPnl(hook);
        vm.revertToState(snap);
        int256 baselinePnl = _withdrawPnl(baseline);
        vm.revertToState(snap);
        console.log("Holster P&L: %d USDC", holsterPnl / 1e18);
        console.log("Re-centering LP P&L: %d USDC", baselinePnl / 1e18);
        assertGt(holsterPnl, 0);
        assertLt(baselinePnl, 0);

        vm.warp(1_000_000 * 60 + 40 * 60);
        vm.setEnv("STEP", "reset");
        demo.run();
        assertTrue(hook.live() && hook.bidOn() && hook.askOn());
        assertTrue(baseline.live() && baseline.bidOn() && baseline.askOn());
        (,, uint256 price,) = hook.bandState();
        assertApproxEqRel(price, 1e18, 1e15);
    }

    /// Running the deploy again starts the demo over: new tokens, new hooks, both pools back at 1.00.
    function test_deployAgainStartsOver() public {
        vm.warp(1_000_000 * 60);
        new DeployV4().run();
        string memory path = string.concat("deployments/v4-", vm.toString(block.chainid), ".json");
        address hook1 = vm.parseJsonAddress(vm.readFile(path), ".hook");
        address base1 = vm.parseJsonAddress(vm.readFile(path), ".base");

        vm.warp(1_000_000 * 60 + 600);
        new DeployV4().run();
        HolsterHook hook2 = HolsterHook(vm.parseJsonAddress(vm.readFile(path), ".hook"));
        assertTrue(address(hook2) != hook1);
        assertTrue(vm.parseJsonAddress(vm.readFile(path), ".base") != base1);
        assertTrue(hook2.live() && hook2.bidOn() && hook2.askOn());
    }

    /// Value the LP gets back on withdraw, minus the 10,000 BASE + 10,000 USDC it put in, both at the pool price.
    function _withdrawPnl(HolsterHook hook) internal returns (int256) {
        address lp = hook.owner();
        (Currency cur0, Currency cur1,,,) = hook.poolKey();
        address c0 = Currency.unwrap(cur0);
        address c1 = Currency.unwrap(cur1);
        (,, uint256 price,) = hook.bandState();
        uint256 b0 = DemoToken(c0).balanceOf(lp);
        uint256 q0 = DemoToken(c1).balanceOf(lp);
        vm.prank(lp);
        hook.withdraw();
        uint256 value = (DemoToken(c0).balanceOf(lp) - b0) * price / 1e18 + DemoToken(c1).balanceOf(lp) - q0;
        return int256(value) - int256(10_000e18 * price / 1e18 + 10_000e18);
    }
}
