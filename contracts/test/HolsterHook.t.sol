// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HolsterHook} from "../src/HolsterHook.sol";

/// Pool: BASE (token0) / USDC (token1), fee 0.3%, start price 1.00.
/// LP funds in the hook: 10,000 BASE + 10,000 USDC, each side ±10%. Another LP provides liquidity over roughly ±45%.
contract HolsterHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant T0 = 1_000_000 * 60; // start of a minute
    uint256 constant BAND_OFF = 1_000_000; // an upper threshold that never triggers

    address lp = makeAddr("lp");
    HolsterHook hook;
    uint256 t; // block.timestamp is cached under via_ir, so the tests keep their own clock

    function _setUp(uint256 upperBps, uint256 lowerBps) internal {
        _setUp(30, upperBps, lowerBps);
    }

    function _setUp(uint256 candles, uint256 upperBps, uint256 lowerBps) internal {
        _setUp(candles, upperBps, lowerBps, 10_000);
    }

    function _setUp(uint256 candles, uint256 upperBps, uint256 lowerBps, uint256 deployBps) internal {
        t = T0;
        vm.warp(t);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address addr = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
                | uint160(uint256(keccak256(abi.encode(candles, upperBps, lowerBps, deployBps))) << 144 >> 16)
        );
        deployCodeTo("HolsterHook.sol:HolsterHook", abi.encode(manager, lp, candles, 1000, upperBps, lowerBps, deployBps), addr);
        hook = HolsterHook(addr);

        (key,) = initPool(currency0, currency1, IHooks(addr), 3000, 10, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 200_000e18, 0), "");

        MockERC20(Currency.unwrap(currency0)).mint(lp, DEPOSIT);
        MockERC20(Currency.unwrap(currency1)).mint(lp, DEPOSIT);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(currency0)).approve(addr, DEPOSIT);
        MockERC20(Currency.unwrap(currency1)).approve(addr, DEPOSIT);
        hook.deposit(DEPOSIT, DEPOSIT);
        vm.stopPrank();
    }

    function _wait(uint256 secs) internal {
        t += secs;
        vm.warp(t);
    }

    /// Swap until the pool reaches the price at `tick`.
    function _swapTo(int24 tick) internal {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        swapRouter.swap(
            key,
            SwapParams(target < sqrtP, -1e30, target),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// LP value in USDC at price 1.00 after withdrawing, minus the 20,000 it started with.
    function _exitPnl() internal returns (int256) {
        vm.prank(lp);
        hook.withdraw();
        uint256 b0 = MockERC20(Currency.unwrap(currency0)).balanceOf(lp);
        uint256 b1 = MockERC20(Currency.unwrap(currency1)).balanceOf(lp);
        return int256(b0 + b1) - int256(2 * DEPOSIT);
    }

    function _log(string memory label) internal view {
        (bool b, bool a, uint256 p, uint256 tw) = hook.bandState();
        (,, uint128 bidL) = hook.bid();
        (,, uint128 askL) = hook.ask();
        console.log(label);
        console.log("   price %d / TWAP %d (x1000)", p / 1e15, tw / 1e15);
        console.log("   band allows bid %s, ask %s", b ? "yes" : "NO", a ? "yes" : "NO");
        console.log("   hook bid L %d, ask L %d (x1e18)", bidL / 1e18, askL / 1e18);
    }

    // ------------------------------------------------------------------ pump & dump

    /// 1.00 -> 1.15 -> 1.00 within one minute. Returns the LP P&L.
    function _pumpAndDump() internal returns (int256 pnl) {
        _log("0) start");
        _wait(5);
        _swapTo(1398); // ~1.15
        _log("1) pumped to 1.15, TWAP still 1.00");
        _wait(12);
        _swapTo(0); // the hook checks the band before this swap
        _log("2) dumped back to 1.00");
        if (hook.needsPoke()) hook.poke();
        _log("3) after poke");
        pnl = _exitPnl();
        console.log("   LP P&L: %d USDC", pnl / 1e18);
    }

    function test_pump_bandOn() public {
        console.log("===== pump & dump, band +/-5% =====");
        _setUp(500, 500);
        int256 pnl = _pumpAndDump();
        assertGt(pnl, 0);
        assertTrue(hook.bidOn() && hook.askOn() || !hook.live());
    }

    function test_pump_bandOff() public {
        console.log("===== pump & dump, no band (re-place when out of range) =====");
        _setUp(BAND_OFF, 9_999);
        int256 pnl = _pumpAndDump();
        assertLt(pnl, 0);
    }

    function test_pump_bandOn_75pct() public {
        console.log("===== pump & dump, band +/-5%, 75% deployed =====");
        _setUp(30, 500, 500, 7_500);
        assertGt(_pumpAndDump(), 0);
    }

    function test_pump_bandOff_75pct() public {
        console.log("===== pump & dump, no band, 75% deployed =====");
        _setUp(30, BAND_OFF, 9_999, 7_500);
        assertLt(_pumpAndDump(), 0);
    }

    // ------------------------------------------------------------------ dump & rebound

    /// 1.00 -> 0.87 -> 1.00 within one minute. Returns the LP P&L.
    function _dumpAndRebound() internal returns (int256 pnl) {
        _wait(5);
        _swapTo(-1393); // ~0.87
        _log("1) dumped to 0.87, TWAP still 1.00");
        _wait(12);
        _swapTo(0);
        _log("2) rebounded to 1.00");
        pnl = _exitPnl();
        console.log("   LP P&L: %d USDC", pnl / 1e18);
    }

    function test_dump_bandOn() public {
        console.log("===== dump & rebound, band +/-5% =====");
        _setUp(500, 500);
        assertGt(_dumpAndRebound(), 0);
    }

    function test_dump_bandOff() public {
        console.log("===== dump & rebound, no band =====");
        _setUp(BAND_OFF, 9_999);
        assertLt(_dumpAndRebound(), 0);
    }

    function test_dump_bandOn_75pct() public {
        console.log("===== dump & rebound, band +/-5%, 75% deployed =====");
        _setUp(30, 500, 500, 7_500);
        assertGt(_dumpAndRebound(), 0);
    }

    function test_dump_bandOff_75pct() public {
        console.log("===== dump & rebound, no band, 75% deployed =====");
        _setUp(30, BAND_OFF, 9_999, 7_500);
        assertLt(_dumpAndRebound(), 0);
    }

    // ------------------------------------------------------------------ recovery

    /// The band stops the bid on a jump and brings it back once the TWAP catches up, with no swap needed in between.
    function test_bidReturnsWhenTwapCatchesUp() public {
        _setUp(500, 500);
        _swapTo(700); // ~ +7.2%
        assertTrue(hook.needsPoke());
        hook.poke();
        assertFalse(hook.bidOn());
        assertTrue(hook.askOn());

        uint256 waited;
        while (!hook.needsPoke()) {
            _wait(60);
            waited++;
            require(waited < 60, "never recovered");
        }
        hook.poke();
        assertTrue(hook.bidOn());
        // 1.072 vs a 30-minute SMA: the SMA reaches 1.072 / 1.05 after 9 minutes.
        assertEq(waited, 9);
    }

    /// A shorter TWAP catches up sooner: with 10 candles the bid returns after 3 minutes instead of 9.
    function test_shorterTwapRecoversSooner() public {
        _setUp(10, 500, 500);
        _swapTo(700);
        hook.poke();
        assertFalse(hook.bidOn());
        uint256 waited;
        while (!hook.needsPoke()) {
            _wait(60);
            waited++;
        }
        assertEq(waited, 3);
    }

    /// With 75% deployed, each side gets 75% of half the value and a quarter stays in the hook as a reserve.
    function test_partialDeployKeepsReserve() public {
        _setUp(30, 500, 500, 7_500);
        address h = address(hook);
        assertApproxEqRel(MockERC20(Currency.unwrap(currency0)).balanceOf(h), 2_500e18, 1e15);
        assertApproxEqRel(MockERC20(Currency.unwrap(currency1)).balanceOf(h), 2_500e18, 1e15);
    }

    /// The owner can change the width at any time; the positions are placed again with it.
    function test_ownerSetsWidth() public {
        _setUp(500, 500);
        (int24 lowerBefore,,) = hook.bid();
        vm.prank(lp);
        hook.setWidth(2000);
        (int24 lowerAfter,,) = hook.bid();
        assertEq(hook.widthBps(), 2000);
        assertLt(lowerAfter, lowerBefore); // the bid now reaches further down
        vm.expectRevert(HolsterHook.NotOwner.selector);
        hook.setWidth(1000);
    }

    function test_onlyOwnerMovesFunds() public {
        _setUp(500, 500);
        vm.expectRevert(HolsterHook.NotOwner.selector);
        hook.withdraw();
    }
}
