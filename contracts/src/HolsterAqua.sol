// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Band} from "./Band.sol";

/// @title HolsterAqua
/// @notice Holster as a 1inch Aqua strategy. The strategy program is a single SwapVM `Extruction` that calls
/// this contract; it prices every quote and swap for the maker's Aqua balances.
///
/// The strategy has a center price C and two ranges: a bid on [C·(1-W), C] funded with quote and an ask on [C, C·(1+W)]
/// funded with base, each with its own concentrated liquidity. Before pricing, the band is checked against the TWAP
/// of the strategy's own prices. When the allowed sides change, or the price has left the range, it is re-placed:
/// C moves to the current price and both liquidities are recomputed from the current balances. Nothing moves on
/// re-placement; the maker's tokens stay in the maker's wallet and Aqua only tracks the budget.
///
/// Quotes run in a static call and never write. Swaps compute the same result and then store the new price, the
/// candles and the state. Only the SwapVM router may call `extruction`, and each order has its own state.
contract HolsterAqua is IExtruction {
    using Band for Band.Oracle;

    /// @dev Opcode of `Extruction` in the 1inch Aqua SwapVM router v1.0.x.
    uint8 public constant EXTRUCTION_OPCODE = 32;

    /// Strategy parameters, packed into the program (they are part of the order hash and cannot change).
    struct Params {
        address base;
        address quote;
        uint16 twapCandles; // number of 1-minute candles in the TWAP
        uint16 widthBps; // each side covers price * (1 ± widthBps)
        uint16 upperBps; // stop the bid above TWAP * (1 + upperBps)
        uint16 lowerBps; // stop the ask below TWAP * (1 - lowerBps)
        uint16 feeBps; // fee on the taker's input, kept by the maker
        uint16 deployBps; // each side gets at most deployBps × half of the maker's value (10000 = every token)
        uint160 sqrtPriceX96; // starting price: sqrt(quote per base) in Q64.96
    }

    struct State {
        uint160 sqrtPriceX96; // current price of the strategy
        uint160 sqrtCenterX96; // center of the last placement
        uint160 sqrtLowerX96; // C·(1-W)
        uint160 sqrtUpperX96; // C·(1+W)
        uint128 bidLiquidity; // liquidity on [lower, center]
        uint128 askLiquidity; // liquidity on [center, upper]
        bool bidOn;
        bool askOn;
        bool live;
        address maker; // set on the first swap
        uint16 widthBps; // width override set by the maker (0 = use the program's width)
    }

    address public immutable router;

    mapping(bytes32 orderHash => State) internal states;
    mapping(bytes32 orderHash => Band.Oracle) internal oracles;

    event Placed(
        bytes32 indexed orderHash, uint160 sqrtCenterX96, bool bidOn, bool askOn, uint128 bidLiquidity, uint128 askLiquidity
    );
    event WidthChanged(bytes32 indexed orderHash, uint16 widthBps);
    event Traded(bytes32 indexed orderHash, bool baseIn, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceX96);

    error OnlyRouter();
    error WrongPair();
    error BadParams();
    error NotEnoughLiquidity();
    error NotMaker();

    constructor(address _router) {
        router = _router;
    }

    // ------------------------------------------------------------------ program

    /// @notice Program bytes for an Aqua order that uses Holster.
    function program(Params calldata p) external view returns (bytes memory) {
        bytes memory args = abi.encodePacked(
            address(this),
            p.base,
            p.quote,
            p.twapCandles,
            p.widthBps,
            p.upperBps,
            p.lowerBps,
            p.feeBps,
            p.deployBps,
            p.sqrtPriceX96
        );
        return abi.encodePacked(EXTRUCTION_OPCODE, uint8(args.length), args);
    }

    function decode(bytes calldata a) public pure returns (Params memory p) {
        if (a.length != 72) revert BadParams();
        p.base = address(bytes20(a[0:20]));
        p.quote = address(bytes20(a[20:40]));
        p.twapCandles = uint16(bytes2(a[40:42]));
        p.widthBps = uint16(bytes2(a[42:44]));
        p.upperBps = uint16(bytes2(a[44:46]));
        p.lowerBps = uint16(bytes2(a[46:48]));
        p.feeBps = uint16(bytes2(a[48:50]));
        p.deployBps = uint16(bytes2(a[50:52]));
        p.sqrtPriceX96 = uint160(bytes20(a[52:72]));
        Band.validate(p.twapCandles, p.widthBps, p.upperBps, p.lowerBps);
        if (p.feeBps >= Band.BPS || p.deployBps == 0 || p.deployBps > Band.BPS || p.sqrtPriceX96 == 0) {
            revert BadParams();
        }
    }

    // ------------------------------------------------------------------ reads

    function state(bytes32 orderHash) external view returns (State memory) {
        return states[orderHash];
    }

    /// @notice Lets the order's maker change the width. It takes effect at the next re-placement.
    function setWidth(bytes32 orderHash, uint16 widthBps) external {
        State storage st = states[orderHash];
        if (!st.live || msg.sender != st.maker) revert NotMaker();
        Band.validate(oracles[orderHash].n, widthBps, 1, 1);
        st.widthBps = widthBps;
        emit WidthChanged(orderHash, widthBps);
    }

    function twap(bytes32 orderHash) external view returns (uint256) {
        return oracles[orderHash].twap();
    }

    // ------------------------------------------------------------------ SwapVM

    /// @inheritdoc IExtruction
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    ) external returns (uint256, uint256, SwapRegisters memory updated) {
        if (msg.sender != router) revert OnlyRouter();
        Params memory p = decode(args);
        bytes32 key = query.orderHash;

        bool baseIn;
        if (query.tokenIn == p.base && query.tokenOut == p.quote) baseIn = true;
        else if (query.tokenIn != p.quote || query.tokenOut != p.base) revert WrongPair();
        (uint256 baseBal, uint256 quoteBal) = baseIn ? (swap.balanceIn, swap.balanceOut) : (swap.balanceOut, swap.balanceIn);

        // 1. band check and, if needed, re-placement around the current price
        State memory d = states[key];
        bool wasLive = d.live;
        uint256 twapPrice;
        if (wasLive) {
            twapPrice = oracles[key].twap();
        } else {
            d.sqrtPriceX96 = p.sqrtPriceX96;
            twapPrice = Band.toPrice(p.sqrtPriceX96);
        }
        uint256 priceBefore = Band.toPrice(d.sqrtPriceX96);
        (bool bidOk, bool askOk) = Band.sides(priceBefore, twapPrice, p.upperBps, p.lowerBps);
        bool replace = !wasLive || bidOk != d.bidOn || askOk != d.askOn || d.sqrtPriceX96 <= d.sqrtLowerX96
            || d.sqrtPriceX96 >= d.sqrtUpperX96;
        if (replace) {
            _place(d, bidOk, askOk, baseBal, quoteBal, d.widthBps == 0 ? p.widthBps : d.widthBps, p.deployBps);
        }

        // 2. price the trade on the two ranges
        updated = swap;
        uint160 sqrtAfter;
        if (query.isExactIn) {
            uint256 net = swap.amountIn * (Band.BPS - p.feeBps) / Band.BPS;
            (sqrtAfter, updated.amountOut) = _exactIn(d, baseIn, net);
        } else {
            uint256 net;
            (sqrtAfter, net) = _exactOut(d, baseIn, swap.amountOut);
            updated.amountIn = (net * Band.BPS + (Band.BPS - p.feeBps) - 1) / (Band.BPS - p.feeBps);
        }

        // 3. swaps store the result; quotes never write
        if (!isStaticContext) {
            Band.Oracle storage o = oracles[key];
            if (!wasLive) {
                o.init(p.twapCandles, priceBefore);
                d.maker = query.maker;
            }
            o.record(priceBefore);
            d.sqrtPriceX96 = sqrtAfter;
            states[key] = d;
            o.record(Band.toPrice(sqrtAfter));
            if (replace) emit Placed(key, d.sqrtCenterX96, d.bidOn, d.askOn, d.bidLiquidity, d.askLiquidity);
            emit Traded(key, baseIn, updated.amountIn, updated.amountOut, sqrtAfter);
        }
        return (nextPC, 0, updated);
    }

    // ------------------------------------------------------------------ ranges

    /// @dev Center the ranges on the current price. Each allowed side gets at most deployBps × half of the maker's
    ///      value; the rest of the Aqua balance stays in reserve for later placements.
    function _place(
        State memory d,
        bool bidOk,
        bool askOk,
        uint256 baseBal,
        uint256 quoteBal,
        uint256 widthBps,
        uint256 deployBps
    ) internal pure {
        uint160 c = d.sqrtPriceX96;
        (uint160 lo, uint160 hi) = Band.bounds(c, widthBps);
        uint256 price = Band.toPrice(c);
        uint256 quoteAmt = quoteBal;
        uint256 baseAmt = baseBal;
        if (deployBps < Band.BPS) {
            uint256 cap = (FullMath.mulDiv(baseBal, price, 1e18) + quoteBal) * deployBps / Band.BPS / 2; // in quote
            uint256 baseCap = FullMath.mulDiv(cap, 1e18, price);
            if (quoteAmt > cap) quoteAmt = cap;
            if (baseAmt > baseCap) baseAmt = baseCap;
        }
        d.sqrtCenterX96 = c;
        d.sqrtLowerX96 = lo;
        d.sqrtUpperX96 = hi;
        d.bidLiquidity = bidOk ? LiquidityAmounts.getLiquidityForAmount1(lo, c, quoteAmt) : 0;
        d.askLiquidity = askOk ? LiquidityAmounts.getLiquidityForAmount0(c, hi, baseAmt) : 0;
        d.bidOn = bidOk;
        d.askOn = askOk;
        d.live = true;
    }

    /// @dev Base in moves the price down: first through the ask range (if above center), then the bid range.
    ///      Quote in moves it up: first through the bid range (if below center), then the ask range.
    function _exactIn(State memory d, bool baseIn, uint256 amountIn) internal pure returns (uint160 s, uint256 out) {
        s = d.sqrtPriceX96;
        uint256 used;
        uint256 got;
        if (baseIn) {
            (s, used, got) = _down(s, d.sqrtCenterX96, d.askLiquidity, amountIn, true);
            amountIn -= used;
            out += got;
            (s, used, got) = _down(s, d.sqrtLowerX96, d.bidLiquidity, amountIn, true);
        } else {
            (s, used, got) = _up(s, d.sqrtCenterX96, d.bidLiquidity, amountIn, true);
            amountIn -= used;
            out += got;
            (s, used, got) = _up(s, d.sqrtUpperX96, d.askLiquidity, amountIn, true);
        }
        if (used < amountIn) revert NotEnoughLiquidity();
        out += got;
    }

    function _exactOut(State memory d, bool baseIn, uint256 amountOut) internal pure returns (uint160 s, uint256 inNet) {
        s = d.sqrtPriceX96;
        uint256 used;
        uint256 got;
        if (baseIn) {
            (s, used, got) = _down(s, d.sqrtCenterX96, d.askLiquidity, amountOut, false);
            amountOut -= got;
            inNet += used;
            (s, used, got) = _down(s, d.sqrtLowerX96, d.bidLiquidity, amountOut, false);
        } else {
            (s, used, got) = _up(s, d.sqrtCenterX96, d.bidLiquidity, amountOut, false);
            amountOut -= got;
            inNet += used;
            (s, used, got) = _up(s, d.sqrtUpperX96, d.askLiquidity, amountOut, false);
        }
        if (got < amountOut) revert NotEnoughLiquidity();
        inNet += used;
    }

    /// @dev One range, price moving down (base in, quote out), not below `floor`. `rem` is the remaining input for
    ///      exact-in, or the remaining output for exact-out. Rounding always favors the maker.
    function _down(uint160 s, uint160 floor, uint128 liq, uint256 rem, bool exactIn)
        internal
        pure
        returns (uint160 next, uint256 used, uint256 got)
    {
        if (liq == 0 || s <= floor || rem == 0) return (s, 0, 0);
        if (exactIn) {
            uint256 maxIn = SqrtPriceMath.getAmount0Delta(floor, s, liq, true);
            if (rem >= maxIn) (next, used) = (floor, maxIn);
            else (next, used) = (SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(s, liq, rem, true), rem);
            got = SqrtPriceMath.getAmount1Delta(next, s, liq, false);
        } else {
            uint256 maxOut = SqrtPriceMath.getAmount1Delta(floor, s, liq, false);
            if (rem >= maxOut) (next, got) = (floor, maxOut);
            else (next, got) = (SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(s, liq, rem, false), rem);
            used = SqrtPriceMath.getAmount0Delta(next, s, liq, true);
        }
    }

    /// @dev One range, price moving up (quote in, base out), not above `cap`.
    function _up(uint160 s, uint160 cap, uint128 liq, uint256 rem, bool exactIn)
        internal
        pure
        returns (uint160 next, uint256 used, uint256 got)
    {
        if (liq == 0 || s >= cap || rem == 0) return (s, 0, 0);
        if (exactIn) {
            uint256 maxIn = SqrtPriceMath.getAmount1Delta(s, cap, liq, true);
            if (rem >= maxIn) (next, used) = (cap, maxIn);
            else (next, used) = (SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(s, liq, rem, true), rem);
            got = SqrtPriceMath.getAmount0Delta(s, next, liq, false);
        } else {
            uint256 maxOut = SqrtPriceMath.getAmount0Delta(s, cap, liq, false);
            if (rem >= maxOut) (next, got) = (cap, maxOut);
            else (next, got) = (SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(s, liq, rem, false), rem);
            used = SqrtPriceMath.getAmount1Delta(s, next, liq, true);
        }
    }
}
