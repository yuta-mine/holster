// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {AquaOpcodes} from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import {Extruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {Context} from "@1inch/swap-vm/src/libs/VM.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {HolsterAqua} from "../src/HolsterAqua.sol";

/// Reads the router's opcode table to find where `Extruction` sits.
contract OpcodeTable is AquaOpcodes {
    constructor() AquaOpcodes(address(1)) {}

    function extructionIndex() external pure returns (uint256 i) {
        function(Context memory, bytes calldata) internal[] memory ops = _opcodes();
        for (; i < ops.length; i++) {
            if (ops[i] == Extruction._extruction) return i;
        }
    }
}

/// Holster on 1inch Aqua: the maker gives 10,000 BASE + 10,000 USDC, start price 1.00, each side ±10%, fee 0.3%, TWAP of 30 candles.
/// The official Aqua and SwapVM router (v1.0.2) are deployed from source; the taker calls the router directly.
contract HolsterAquaTest is Test {
    uint256 constant DEPOSIT = 10_000e18;
    uint160 constant SQRT_1 = 1 << 96; // price 1.00
    uint256 constant T0 = 1_000_000 * 60;

    Aqua aqua;
    AquaSwapVMRouter router;
    HolsterAqua holster;
    TokenMock base;
    TokenMock quote;
    address maker = makeAddr("maker");
    ISwapVM.Order order;
    bytes32 orderHash;
    uint256 t;

    function _setUp(uint16 upperBps, uint16 lowerBps) internal {
        t = T0;
        vm.warp(t);
        aqua = new Aqua();
        router = new AquaSwapVMRouter(address(aqua), address(0), address(this), "SwapVM", "1.0.2");
        holster = new HolsterAqua(address(router));
        base = new TokenMock("Base", "BASE");
        quote = new TokenMock("USD", "USDC");

        bytes memory prog = holster.program(
            HolsterAqua.Params({
                base: address(base),
                quote: address(quote),
                twapCandles: 30,
                widthBps: 1000,
                upperBps: upperBps,
                lowerBps: lowerBps,
                feeBps: 30,
                deployBps: 10_000,
                sqrtPriceX96: SQRT_1
            })
        );
        order = MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
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
                program: prog
            })
        );

        // The maker keeps the tokens in its wallet and only approves Aqua.
        base.mint(maker, DEPOSIT);
        quote.mint(maker, DEPOSIT);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(base), address(quote));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (DEPOSIT, DEPOSIT);
        vm.startPrank(maker);
        base.approve(address(aqua), type(uint256).max);
        quote.approve(address(aqua), type(uint256).max);
        orderHash = aqua.ship(address(router), abi.encode(order), tokens, amounts);
        vm.stopPrank();
        assertEq(orderHash, router.hash(order));

        base.mint(address(this), 1_000_000e18);
        quote.mint(address(this), 1_000_000e18);
        base.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
    }

    function _wait(uint256 secs) internal {
        t += secs;
        vm.warp(t);
    }

    function _takerData(bool exactIn) internal view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: exactIn,
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
    }

    function _swap(address tokenIn, address tokenOut, uint256 amount, bool exactIn)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut,) = router.swap(order, tokenIn, tokenOut, amount, _takerData(exactIn));
    }

    function _quote(address tokenIn, address tokenOut, uint256 amount, bool exactIn)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut,) = router.asView().quote(order, tokenIn, tokenOut, amount, _takerData(exactIn));
    }

    /// Buys every BASE left on the ask, which takes the price to the top of the range.
    function _buyAllBase() internal returns (uint256 paid) {
        (uint256 p0,) = _swap(address(quote), address(base), 1e18, false); // the first trade places the ranges
        HolsterAqua.State memory d = holster.state(orderHash);
        uint256 left = SqrtPriceMath.getAmount0Delta(d.sqrtPriceX96, d.sqrtUpperX96, d.askLiquidity, false);
        (uint256 p1,) = _swap(address(quote), address(base), left, false);
        return p0 + p1;
    }

    /// Maker value at price 1.00, minus the 20,000 it started with.
    function _makerPnl() internal view returns (int256) {
        (uint256 b, uint256 q) = aqua.safeBalances(maker, address(router), orderHash, address(base), address(quote));
        return int256(b + q) - int256(2 * DEPOSIT);
    }

    function _log(string memory label) internal view {
        HolsterAqua.State memory d = holster.state(orderHash);
        uint256 p = uint256(d.sqrtPriceX96) * d.sqrtPriceX96 / 2 ** 96 * 1e3 / 2 ** 96;
        (uint256 b, uint256 q) = aqua.safeBalances(maker, address(router), orderHash, address(base), address(quote));
        console.log(label);
        console.log("   price %d / TWAP %d (x1000)", p, holster.twap(orderHash) / 1e15);
        console.log("   bid %s, ask %s", d.bidOn ? "on" : "OFF", d.askOn ? "on" : "OFF");
        console.log("   maker Aqua balances: BASE %d, USDC %d", b / 1e18, q / 1e18);
    }

    // ------------------------------------------------------------------ pump & dump

    /// The attacker buys every BASE on the ask (1.00 -> 1.10), then tries to sell it back.
    function _pumpAndDump() internal returns (bool dumpFilled) {
        _wait(5);
        uint256 paid = _buyAllBase();
        _log("1) attacker bought every BASE on the ask (1.00 -> 1.10)");
        console.log("   attacker paid %d USDC", paid / 1e18);
        _wait(12);
        try router.swap(order, address(base), address(quote), 9_990e18, _takerData(true)) returns (uint256, uint256 got, bytes32) {
            dumpFilled = true;
            console.log("2) dump filled: attacker got %d USDC back", got / 1e18);
        } catch {
            console.log("2) dump refused by Holster");
        }
        _log("   after the dump");
        console.log("   maker P&L at 1.00: %d USDC", _makerPnl() / 1e18);
    }

    function test_pump_bandOn() public {
        console.log("===== Aqua pump & dump, band +/-5% =====");
        _setUp(500, 500);
        assertFalse(_pumpAndDump());
        assertGt(_makerPnl(), 0);
    }

    function test_pump_bandOff() public {
        console.log("===== Aqua pump & dump, no band (re-center when out of range) =====");
        _setUp(type(uint16).max, 9_999);
        assertTrue(_pumpAndDump());
        assertLt(_makerPnl(), 0);
    }

    /// After a jump Holster refuses to buy; once the TWAP catches up it buys again around the new price.
    function test_bidReturnsWhenTwapCatchesUp() public {
        _setUp(500, 500);
        _buyAllBase();
        uint256 waited;
        while (true) {
            _wait(60);
            waited++;
            try this.quoteSell(1e18) returns (uint256) {
                break;
            } catch {}
            require(waited < 60, "never recovered");
        }
        // 1.10 vs a 30-candle SMA: the SMA reaches 1.10 / 1.05 after 15 minutes.
        assertEq(waited, 15);
        _swap(address(base), address(quote), 1e18, true);
        assertTrue(holster.state(orderHash).bidOn);
    }

    function quoteSell(uint256 amount) external view returns (uint256 out) {
        (, out) = _quote(address(base), address(quote), amount, true);
    }

    /// A quote and the swap that follows give the same amounts, for both directions and both modes.
    function test_quoteMatchesSwap() public {
        _setUp(500, 500);
        (uint256 qi, uint256 qo) = _quote(address(quote), address(base), 2_000e18, true);
        (uint256 si, uint256 so) = _swap(address(quote), address(base), 2_000e18, true);
        assertEq(qi, si);
        assertEq(qo, so);
        (qi, qo) = _quote(address(base), address(quote), 500e18, false);
        (si, so) = _swap(address(base), address(quote), 500e18, false);
        assertEq(qi, si);
        assertEq(qo, so);
    }

    /// A small round trip inside the band leaves the maker with more than it started (fees, maker-side rounding).
    function test_roundTripEarnsFees() public {
        _setUp(500, 500);
        (, uint256 gotBase) = _swap(address(quote), address(base), 1_000e18, true);
        _swap(address(base), address(quote), gotBase, true);
        assertGt(_makerPnl(), 0);
    }

    function test_opcodeMatchesRouter() public {
        _setUp(500, 500);
        assertEq(holster.EXTRUCTION_OPCODE(), new OpcodeTable().extructionIndex());
    }

    /// Only the order's maker can change the width, and the next placement uses it.
    function test_makerSetsWidth() public {
        _setUp(500, 500);
        _swap(address(quote), address(base), 1e18, false); // first trade makes the strategy live
        vm.expectRevert(HolsterAqua.NotMaker.selector);
        holster.setWidth(orderHash, 2000);
        vm.prank(maker);
        holster.setWidth(orderHash, 2000);
        assertEq(holster.state(orderHash).widthBps, 2000);
    }

    function test_onlyRouterCallsExtruction() public {
        _setUp(500, 500);
        vm.expectRevert(HolsterAqua.OnlyRouter.selector);
        holster.extruction(
            false,
            0,
            SwapQuery({orderHash: 0, maker: maker, taker: address(this), tokenIn: address(base), tokenOut: address(quote), isExactIn: true}),
            SwapRegisters({balanceIn: 0, balanceOut: 0, amountIn: 0, amountOut: 0, amountNetPulled: 0}),
            "",
            ""
        );
    }
}
