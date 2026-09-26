// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployV4} from "../script/DeployV4.s.sol";
import {DemoV4} from "../script/DemoV4.s.sol";
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
}
