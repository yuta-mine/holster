// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Band} from "./Band.sol";

/// @title HolsterHook
/// @notice Uniswap v4 hook that manages an LP's liquidity with a TWAP price band.
/// The hook holds the owner's tokens and keeps two positions in its pool: a bid below the price (holding quote,
/// token1) and an ask above it (holding base, token0). Before every swap it checks the band; when the allowed
/// sides change or the price leaves the range, it pulls both positions and places the allowed sides next to the
/// current price. The same check can be triggered by anyone with `poke()`; `needsPoke()` is a free read.
contract HolsterHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using Band for Band.Oracle;
    using PoolIdLibrary for PoolKey;

    bytes32 private constant SALT_BID = bytes32(uint256(1));
    bytes32 private constant SALT_ASK = bytes32(uint256(2));

    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    address public immutable owner;
    uint256 public immutable twapCandles; // number of 1-minute candles in the TWAP
    uint256 public immutable upperBps; // stop the bid above TWAP * (1 + upperBps)
    uint256 public immutable lowerBps; // stop the ask below TWAP * (1 - lowerBps)
    uint256 public immutable deployBps; // each side gets at most deployBps × half of the LP's value (10000 = every token)

    uint256 public widthBps; // each side covers price * (1 ± widthBps); the owner can change it

    PoolKey public poolKey;
    PoolId public poolId;
    Band.Oracle internal oracle;

    Position public bid;
    Position public ask;
    bool public live;
    bool public bidOn;
    bool public askOn;
    uint160 public centerSqrtPriceX96;

    event BandChanged(bool bidOn, bool askOn, uint256 price, uint256 twap);
    event Placed(uint160 centerSqrtPriceX96, uint128 bidLiquidity, uint128 askLiquidity);
    event WidthChanged(uint256 widthBps);

    error NotOwner();
    error PoolAlreadySet();

    constructor(
        IPoolManager _poolManager,
        address _owner,
        uint256 _twapCandles,
        uint256 _widthBps,
        uint256 _upperBps,
        uint256 _lowerBps,
        uint256 _deployBps
    ) BaseHook(_poolManager) {
        Band.validate(_twapCandles, _widthBps, _upperBps, _lowerBps);
        if (_deployBps == 0 || _deployBps > Band.BPS) revert Band.BandConfigInvalid();
        owner = _owner;
        twapCandles = _twapCandles;
        widthBps = _widthBps;
        upperBps = _upperBps;
        lowerBps = _lowerBps;
        deployBps = _deployBps;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // ------------------------------------------------------------------ owner

    /// @notice Moves tokens into the hook and places them in the pool.
    function deposit(uint256 amount0, uint256 amount1) external {
        if (msg.sender != owner) revert NotOwner();
        IERC20Minimal(Currency.unwrap(poolKey.currency0)).transferFrom(msg.sender, address(this), amount0);
        IERC20Minimal(Currency.unwrap(poolKey.currency1)).transferFrom(msg.sender, address(this), amount1);
        poolManager.unlock(abi.encode(true));
    }

    /// @notice Changes the width of each side. The positions are placed again right away with the new width.
    function setWidth(uint256 _widthBps) external {
        if (msg.sender != owner) revert NotOwner();
        Band.validate(twapCandles, _widthBps, upperBps, lowerBps);
        widthBps = _widthBps;
        emit WidthChanged(_widthBps);
        if (live) poolManager.unlock(abi.encode(true));
    }

    /// @notice Pulls both positions (with fees) and sends every token back to the owner.
    function withdraw() external {
        if (msg.sender != owner) revert NotOwner();
        poolManager.unlock(abi.encode(false));
        _send(poolKey.currency0, owner, _balance(poolKey.currency0));
        _send(poolKey.currency1, owner, _balance(poolKey.currency1));
    }

    // ------------------------------------------------------------------ anyone

    /// @notice True when the positions should be re-placed now. Free to call; keepers poll this.
    function needsPoke() public view returns (bool) {
        if (!live) return false;
        (bool b, bool a,,) = bandState();
        if (b != bidOn || a != askOn) return true;
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        (uint160 lo, uint160 hi) = Band.bounds(centerSqrtPriceX96, widthBps);
        return sqrtP < lo || sqrtP > hi;
    }

    /// @notice Re-places the positions if `needsPoke()`. The same thing also happens before every swap.
    function poke() external {
        if (needsPoke()) poolManager.unlock(abi.encode(true));
    }

    /// @notice Current price, TWAP and the sides the band allows at this moment.
    function bandState() public view returns (bool bidOk, bool askOk, uint256 price, uint256 twapPrice) {
        price = currentPrice();
        twapPrice = oracle.twap();
        (bidOk, askOk) = Band.sides(price, twapPrice, upperBps, lowerBps);
    }

    function twap() external view returns (uint256) {
        return oracle.twap();
    }

    function currentPrice() public view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        return Band.toPrice(sqrtP);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (abi.decode(data, (bool))) {
            _place();
        } else {
            _pullAll();
            live = false;
        }
        return "";
    }

    // ------------------------------------------------------------------ hooks

    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        if (PoolId.unwrap(poolId) != bytes32(0)) revert PoolAlreadySet();
        poolKey = key;
        poolId = key.toId();
        oracle.init(twapCandles, Band.toPrice(sqrtPriceX96));
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        oracle.record(currentPrice());
        if (needsPoke()) _place(); // the pool manager is already unlocked by the swapper
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        oracle.record(currentPrice());
        return (this.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------ positions

    /// @dev Pull both positions, then place the sides the band allows next to the current price.
    function _place() internal {
        _pullAll();
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(poolId);
        (bool b, bool a, uint256 price, uint256 twapPrice) = bandState();
        if (!live || b != bidOn || a != askOn) emit BandChanged(b, a, price, twapPrice);

        int24 s = poolKey.tickSpacing;
        int24 below = _floor(tick, s); // bid upper: at or below the current tick
        (uint160 lo, uint160 hi) = Band.bounds(sqrtP, widthBps);

        // Each side gets at most deployBps × half of the LP's value; the rest stays in the hook as a reserve.
        uint256 base = _balance(poolKey.currency0);
        uint256 quote = _balance(poolKey.currency1);
        uint256 cap = deployBps >= Band.BPS
            ? type(uint256).max // 100%: place every token
            : (FullMath.mulDiv(base, price, 1e18) + quote) * deployBps / Band.BPS / 2; // in quote

        if (b) {
            Position memory p = Position(_floor(TickMath.getTickAtSqrtPrice(lo), s), below, 0);
            if (p.lower < p.upper) {
                p.liquidity = LiquidityAmounts.getLiquidityForAmount1(
                    TickMath.getSqrtPriceAtTick(p.lower), TickMath.getSqrtPriceAtTick(p.upper), _min(quote, cap)
                );
                _modify(p, int256(uint256(p.liquidity)), SALT_BID);
                bid = p;
            }
        }
        if (a) {
            Position memory p = Position(below + s, _floor(TickMath.getTickAtSqrtPrice(hi), s) + s, 0);
            if (p.lower < p.upper) {
                p.liquidity = LiquidityAmounts.getLiquidityForAmount0(
                    TickMath.getSqrtPriceAtTick(p.lower),
                    TickMath.getSqrtPriceAtTick(p.upper),
                    deployBps >= Band.BPS ? base : _min(base, FullMath.mulDiv(cap, 1e18, price))
                );
                _modify(p, int256(uint256(p.liquidity)), SALT_ASK);
                ask = p;
            }
        }
        bidOn = b;
        askOn = a;
        centerSqrtPriceX96 = sqrtP;
        live = true;
        emit Placed(sqrtP, bid.liquidity, ask.liquidity);
    }

    function _pullAll() internal {
        if (bid.liquidity > 0) _modify(bid, -int256(uint256(bid.liquidity)), SALT_BID);
        if (ask.liquidity > 0) _modify(ask, -int256(uint256(ask.liquidity)), SALT_ASK);
        delete bid;
        delete ask;
    }

    function _modify(Position memory p, int256 liquidityDelta, bytes32 salt) internal {
        if (liquidityDelta == 0) return;
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(poolKey, ModifyLiquidityParams(p.lower, p.upper, liquidityDelta, salt), "");
        _settle(poolKey.currency0, delta.amount0());
        _settle(poolKey.currency1, delta.amount1());
    }

    /// @dev Pay what the hook owes the pool manager, or take what it is owed.
    function _settle(Currency c, int128 amount) internal {
        if (amount < 0) {
            poolManager.sync(c);
            _send(c, address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(c, address(this), uint256(uint128(amount)));
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 f = tick / spacing * spacing;
        if (tick < 0 && tick % spacing != 0) f -= spacing;
        return f;
    }

    function _balance(Currency c) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this));
    }

    function _send(Currency c, address to, uint256 amount) internal {
        if (amount > 0) IERC20Minimal(Currency.unwrap(c)).transfer(to, amount);
    }
}
