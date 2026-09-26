// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployAqua} from "../script/DeployAqua.s.sol";
import {DemoAqua} from "../script/DemoAqua.s.sol";
import {HolsterAqua} from "../src/HolsterAqua.sol";

/// Runs the Aqua deploy and demo scripts end to end on the test chain.
contract ScriptsAquaTest is Test {
    function test_deployAndDemoAqua() public {
        vm.warp(1_000_000 * 60);
        new DeployAqua().run();
        string memory json = vm.readFile(string.concat("deployments/aqua-", vm.toString(block.chainid), ".json"));
        HolsterAqua holster = HolsterAqua(vm.parseJsonAddress(json, ".holster"));
        bytes32 orderHash = vm.parseJsonBytes32(json, ".orderHash");

        DemoAqua demo = new DemoAqua();
        vm.setEnv("STEP", "pump");
        vm.setEnv("AMOUNT", "3500000000000000000000"); // 3,500 of the 3,750 BASE on the ask: price ~1.00 -> ~1.09
        demo.run();
        assertTrue(holster.state(orderHash).live);

        vm.warp(1_000_000 * 60 + 12);
        vm.setEnv("STEP", "dump");
        vm.setEnv("AMOUNT", "1000000000000000000000");
        demo.run(); // refused: the price is more than 5% above the TWAP
        HolsterAqua.State memory d = holster.state(orderHash);
        assertTrue(d.bidOn && d.askOn); // the refused swap did not change the stored state
    }
}
