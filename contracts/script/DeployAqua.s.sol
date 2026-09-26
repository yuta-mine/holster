// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {HolsterAqua} from "../src/HolsterAqua.sol";
import {DemoToken} from "./DemoToken.sol";

/// @notice Deploys 1inch Aqua and the Aqua SwapVM router (v1.0.2, from source), HolsterAqua, demo tokens, and
///         ships a Holster strategy from the deployer.
///
/// 1inch has no official testnet deployment, so on Base Sepolia this deploys its own copies. On chains where 1inch
/// is live, set AQUA and ROUTER to the official addresses to reuse them.
///   forge script script/DeployAqua.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
///
/// Parameters (env, optional): TWAP_CANDLES=30 WIDTH_BPS=1000 UPPER_BPS=500 LOWER_BPS=500 FEE_BPS=30 DEPLOY_BPS=7500
contract DeployAqua is Script {
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    uint160 constant SQRT_PRICE_1 = 1 << 96;
    uint256 constant DEPOSIT = 10_000e18;

    function run() external {
        HolsterAqua.Params memory p;
        p.twapCandles = uint16(vm.envOr("TWAP_CANDLES", uint256(30)));
        p.widthBps = uint16(vm.envOr("WIDTH_BPS", uint256(1000)));
        p.upperBps = uint16(vm.envOr("UPPER_BPS", uint256(500)));
        p.lowerBps = uint16(vm.envOr("LOWER_BPS", uint256(500)));
        p.feeBps = uint16(vm.envOr("FEE_BPS", uint256(30)));
        p.deployBps = uint16(vm.envOr("DEPLOY_BPS", uint256(7_500)));
        p.sqrtPriceX96 = SQRT_PRICE_1;

        vm.startBroadcast();
        (, address me,) = vm.readCallers();

        address aqua = vm.envOr("AQUA", address(0));
        if (aqua == address(0)) aqua = address(new Aqua());
        address router = vm.envOr("ROUTER", address(0));
        if (router == address(0)) {
            router = address(new AquaSwapVMRouter(aqua, vm.envOr("WETH", WETH_BASE), me, "SwapVM", "1.0.2"));
        }
        HolsterAqua holster = new HolsterAqua(router);

        DemoToken base = new DemoToken("Holster Base", "BASE");
        DemoToken quote = new DemoToken("Holster USD", "USDC");
        p.base = address(base);
        p.quote = address(quote);

        ISwapVM.Order memory order = MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: me,
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                receiver: address(0),
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: holster.program(p)
            })
        );

        // The maker keeps the tokens and gives Aqua a budget of 10,000 BASE + 10,000 USDC for this strategy.
        base.mint(me, 1_000_000e18);
        quote.mint(me, 1_000_000e18);
        base.approve(aqua, type(uint256).max);
        quote.approve(aqua, type(uint256).max);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(base), address(quote));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (DEPOSIT, DEPOSIT);
        bytes32 orderHash = Aqua(aqua).ship(router, abi.encode(order), tokens, amounts);
        vm.stopBroadcast();

        string memory o = "aqua";
        vm.serializeAddress(o, "aqua", aqua);
        vm.serializeAddress(o, "router", router);
        vm.serializeAddress(o, "holster", address(holster));
        vm.serializeAddress(o, "base", address(base));
        vm.serializeAddress(o, "quote", address(quote));
        vm.serializeBytes32(o, "orderHash", orderHash);
        string memory json = vm.serializeBytes(o, "order", abi.encode(order));
        vm.writeJson(json, string.concat("deployments/aqua-", vm.toString(block.chainid), ".json"));

        console.log("Aqua       ", aqua);
        console.log("Router     ", router);
        console.log("HolsterAqua", address(holster));
        console.log("BASE       ", address(base));
        console.log("USDC       ", address(quote));
        console.logBytes32(orderHash);
    }
}
