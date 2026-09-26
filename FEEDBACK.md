# Uniswap v4 feedback

Notes from building Holster, a hook that owns LP liquidity and moves it inside `beforeSwap`.

## What worked well

- Moving the hook's own liquidity inside `beforeSwap` (`modifyLiquidity`, then settle/take while the manager is already unlocked) works cleanly ([HolsterHook.sol](contracts/src/HolsterHook.sol#L176-L257)).
- OpenZeppelin's `BaseHook` made the hook itself short.
- Having the official PoolManager on Base Sepolia made it easy to test against a real deployment.

## Pain points

- **Deploying a hook from a Foundry script.** `new Hook{salt: ...}()` in a script was not always deployed through the CREATE2 factory, so the mined address did not match and Base Sepolia rejected it with `HookAddressNotValid`. We fixed it by calling the factory directly ([DeployV4.s.sol](contracts/script/DeployV4.s.sol#L96-L111)). A documented, script-safe deploy helper would save time.
- **Test routers are UNLICENSED.** `PoolSwapTest` and `PoolModifyLiquidityTest` cannot be reused in an open-source project, so we wrote our own router for the testnet demo ([DemoRouter.sol](contracts/script/DemoRouter.sol)). A permissively licensed minimal router would help.
- **No guide for hook-owned liquidity.** We found no official example of a hook that holds its own positions and re-places them during a swap. A short guide covering the unlock state, deltas and settle/take would be useful.
