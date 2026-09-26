// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Minimal router for demos: swap to a price limit, or add liquidity. The caller pays with its own tokens
///         (approve this router first) and receives the output.
contract DemoRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(msg.sender, key, true, abi.encode(SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96)))),
            (BalanceDelta)
        );
    }

    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
        manager.unlock(
            abi.encode(msg.sender, key, false, abi.encode(ModifyLiquidityParams(tickLower, tickUpper, int256(liquidity), 0)))
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, bool isSwap, bytes memory params) =
            abi.decode(data, (address, PoolKey, bool, bytes));
        BalanceDelta delta;
        if (isSwap) delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        else (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency c, address payer, int128 amount) internal {
        if (amount < 0) {
            manager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transferFrom(payer, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, payer, uint256(uint128(amount)));
        }
    }
}
