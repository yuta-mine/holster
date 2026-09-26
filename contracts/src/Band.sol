// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Band
/// @notice Shared rules of Holster, used by both the Uniswap v4 hook and the 1inch Aqua strategy.
///
/// Price = quote per base, 1e18 fixed point. TWAP = simple average of the closes of the last `n` finished 1-minute
/// candles (`n` is set by the LP). A candle closes at the last price seen in that minute; minutes without trades carry
/// the previous close. The candle in progress is excluded.
///
/// The band compares the current price with the TWAP:
///   price > TWAP * (1 + upperBps)  -> the bid (buying base) is stopped
///   price < TWAP * (1 - lowerBps)  -> the ask (selling base) is stopped
/// When the allowed sides change, or the price leaves the range, the liquidity is re-placed around the current price.
library Band {
    uint256 internal constant MAX_CANDLES = 240;
    uint256 internal constant CANDLE_SECONDS = 60;
    uint256 internal constant BPS = 10_000;

    struct Oracle {
        uint256[MAX_CANDLES] closes; // indexed by minute % n
        uint256 n; // number of candles in the TWAP
        uint256 minute; // minute of the candle currently being built
        uint256 last; // last price seen
    }

    error BandConfigInvalid();

    /// @notice Sets the TWAP length and fills every candle with `price`.
    function init(Oracle storage o, uint256 n, uint256 price) internal {
        if (n == 0 || n > MAX_CANDLES) revert BandConfigInvalid();
        for (uint256 i; i < n; i++) {
            o.closes[i] = price;
        }
        o.n = n;
        o.minute = block.timestamp / CANDLE_SECONDS;
        o.last = price;
    }

    /// @notice Closes the candles that finished since the last record, then records `price` as the latest price.
    function record(Oracle storage o, uint256 price) internal {
        uint256 m = block.timestamp / CANDLE_SECONDS;
        uint256 cur = o.minute;
        if (m > cur) {
            uint256 n = o.n;
            uint256 k = m - cur;
            if (k > n) k = n;
            uint256 last = o.last;
            for (uint256 i; i < k; i++) {
                o.closes[(cur + i) % n] = last;
            }
            o.minute = m;
        }
        o.last = price;
    }

    /// @notice SMA of the last `n` finished 1-minute candles.
    function twap(Oracle storage o) internal view returns (uint256) {
        uint256 n = o.n;
        uint256 m = block.timestamp / CANDLE_SECONDS;
        if (m < n) return o.last; // only on chains younger than the window (local test chains)
        uint256 cur = o.minute;
        uint256 last = o.last;
        uint256 sum;
        for (uint256 j = m - n; j < m; j++) {
            sum += j < cur ? o.closes[j % n] : last;
        }
        return sum / n;
    }

    /// @notice Which sides the band allows at `price` given `twapPrice`.
    function sides(uint256 price, uint256 twapPrice, uint256 upperBps, uint256 lowerBps)
        internal
        pure
        returns (bool bidOk, bool askOk)
    {
        bidOk = price * BPS <= twapPrice * (BPS + upperBps);
        askOk = price * BPS >= twapPrice * (BPS - lowerBps);
    }

    function validate(uint256 candles, uint256 widthBps, uint256 upperBps, uint256 lowerBps) internal pure {
        if (
            candles == 0 || candles > MAX_CANDLES || widthBps == 0 || widthBps >= BPS || upperBps == 0 || lowerBps == 0
                || lowerBps >= BPS
        ) revert BandConfigInvalid();
    }

    /// @notice sqrt prices of center * (1 - widthBps) and center * (1 + widthBps).
    function bounds(uint160 sqrtCenterX96, uint256 widthBps) internal pure returns (uint160 lower, uint160 upper) {
        lower = uint160(FullMath.mulDiv(sqrtCenterX96, Math.sqrt((BPS - widthBps) * 1e32), 1e18));
        upper = uint160(FullMath.mulDiv(sqrtCenterX96, Math.sqrt((BPS + widthBps) * 1e32), 1e18));
    }

    /// @notice Price (quote per base, 1e18) of a sqrt price in Q64.96 where base is token0.
    function toPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96), 1e18, 1 << 96);
    }
}
