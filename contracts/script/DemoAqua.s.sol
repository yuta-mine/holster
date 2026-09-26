// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {HolsterAqua} from "../src/HolsterAqua.sol";

/// @notice Takes from a deployed Holster Aqua strategy (reads deployments/aqua-<chainid>.json).
///   STEP=pump  buys AMOUNT BASE (exact out, default 3,000) with USDC
///   STEP=dump  sells AMOUNT BASE (exact in); refused while the band stops the bid
///   forge script script/DemoAqua.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
contract DemoAqua is Script {
    function run() external {
        string memory json = vm.readFile(string.concat("deployments/aqua-", vm.toString(block.chainid), ".json"));
        AquaSwapVMRouter router = AquaSwapVMRouter(payable(vm.parseJsonAddress(json, ".router")));
        HolsterAqua holster = HolsterAqua(vm.parseJsonAddress(json, ".holster"));
        address base = vm.parseJsonAddress(json, ".base");
        address quote = vm.parseJsonAddress(json, ".quote");
        bytes32 orderHash = vm.parseJsonBytes32(json, ".orderHash");
        ISwapVM.Order memory order = abi.decode(vm.parseJsonBytes(json, ".order"), (ISwapVM.Order));
        bool pump = keccak256(bytes(vm.envOr("STEP", string("pump")))) == keccak256("pump");
        uint256 amount = vm.envOr("AMOUNT", uint256(3_000e18));

        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        IERC20(base).approve(address(router), type(uint256).max);
        IERC20(quote).approve(address(router), type(uint256).max);
        bytes memory takerData = TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: me,
                isExactIn: !pump,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: true,
                useTransferFromAndAquaPush: true,
                threshold: "",
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
        if (pump) {
            (uint256 paid,,) = router.swap(order, quote, base, amount, takerData);
            console.log("bought %d BASE for %d USDC", amount / 1e18, paid / 1e18);
        } else {
            // Quote first (free), so a refused trade is never sent on-chain.
            try router.asView().quote(order, base, quote, amount, takerData) returns (uint256, uint256, bytes32) {
                (, uint256 got,) = router.swap(order, base, quote, amount, takerData);
                console.log("sold %d BASE for %d USDC", amount / 1e18, got / 1e18);
            } catch {
                console.log("Holster refused to buy (bid stopped by the band)");
            }
        }
        vm.stopBroadcast();

        HolsterAqua.State memory d = holster.state(orderHash);
        console.log("bid on %s, ask on %s", d.bidOn ? "yes" : "no", d.askOn ? "yes" : "no");
        console.log("TWAP x1000 %d", holster.twap(orderHash) / 1e15);
    }
}
