// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HolsterHook} from "../src/HolsterHook.sol";
import {DemoToken} from "./DemoToken.sol";
import {DemoRouter} from "./DemoRouter.sol";
import {HookDeployer} from "./HookDeployer.sol";

/// @notice Sets up the v4 demo from scratch: new demo tokens, a router, and two pools with the same tokens, fee,
///         background liquidity and deposit (10,000 BASE + 10,000 USDC). One pool has the Holster band; the other has
///         the band switched off, i.e. an LP that only re-places when the price leaves its range. Run it again to start
///         the demo over with fresh tokens and pools (then `node frontend/sync-config.mjs`).
///
/// Base Sepolia (uses the official PoolManager):
///   forge script script/DeployV4.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
/// Anywhere without a PoolManager (e.g. a local anvil), one is deployed first.
///
/// Parameters (env, optional): TWAP_CANDLES=30 WIDTH_BPS=1000 UPPER_BPS=500 LOWER_BPS=500 DEPLOY_BPS=7500
contract DeployV4 is HookDeployer {
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    uint160 constant SQRT_PRICE_1 = 1 << 96;
    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant BACKGROUND_LIQUIDITY = 200_000e18;
    uint256 constant BAND_OFF_UPPER = 1_000_000; // never stops the bid
    uint256 constant BAND_OFF_LOWER = 9_999; // never stops the ask

    struct Setup {
        IPoolManager manager;
        DemoRouter router;
        DemoToken base;
        DemoToken quote;
        address me;
        uint256 candles;
        uint256 width;
        uint256 deployBps;
    }

    function run() external {
        vm.startBroadcast();
        Setup memory s;
        (, s.me,) = vm.readCallers();
        s.candles = vm.envOr("TWAP_CANDLES", uint256(30));
        s.width = vm.envOr("WIDTH_BPS", uint256(1000));
        s.deployBps = vm.envOr("DEPLOY_BPS", uint256(7_500));

        s.manager = IPoolManager(vm.envOr("POOL_MANAGER", BASE_SEPOLIA_POOL_MANAGER));
        if (address(s.manager).code.length == 0) s.manager = new PoolManager(s.me);

        // Demo tokens, deployed so that BASE is currency0 and USDC is currency1.
        (s.base, s.quote) = _tokens();
        s.router = new DemoRouter(s.manager);
        s.base.mint(s.me, 1_000_000e18);
        s.quote.mint(s.me, 1_000_000e18);
        s.base.approve(address(s.router), type(uint256).max);
        s.quote.approve(address(s.router), type(uint256).max);

        HolsterHook hook = _pool(s, vm.envOr("UPPER_BPS", uint256(500)), vm.envOr("LOWER_BPS", uint256(500)));
        HolsterHook baseline = _pool(s, BAND_OFF_UPPER, BAND_OFF_LOWER);
        vm.stopBroadcast();

        string memory o = "v4";
        vm.serializeAddress(o, "poolManager", address(s.manager));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "router", address(s.router));
        vm.serializeAddress(o, "base", address(s.base));
        string memory json = vm.serializeAddress(o, "quote", address(s.quote));
        vm.writeJson(json, string.concat("deployments/v4-", vm.toString(block.chainid), ".json"));
        vm.writeJson(
            vm.serializeAddress("baseline", "hook", address(baseline)),
            string.concat("deployments/v4-baseline-", vm.toString(block.chainid), ".json")
        );

        console.log("PoolManager", address(s.manager));
        console.log("HolsterHook", address(hook));
        console.log("Band off   ", address(baseline));
        console.log("DemoRouter ", address(s.router));
        console.log("BASE       ", address(s.base));
        console.log("USDC       ", address(s.quote));
    }

    /// @dev A hook with the given band, its pool at 1.00, another LP's liquidity (about ±45% around 1.00),
    ///      and the LP's deposit of 10,000 BASE + 10,000 USDC.
    function _pool(Setup memory s, uint256 upper, uint256 lower) internal returns (HolsterHook hook) {
        // The hook address must carry the permission flags, so the salt is mined.
        bytes memory initCode = abi.encodePacked(
            type(HolsterHook).creationCode, abi.encode(s.manager, s.me, s.candles, s.width, upper, lower, s.deployBps)
        );
        hook = HolsterHook(_create2(_mineSalt(keccak256(initCode)), initCode));

        PoolKey memory key = PoolKey(
            Currency.wrap(address(s.base)), Currency.wrap(address(s.quote)), 3000, 10, IHooks(address(hook))
        );
        s.manager.initialize(key, SQRT_PRICE_1);
        s.router.addLiquidity(key, -6000, 6000, BACKGROUND_LIQUIDITY);

        s.base.approve(address(hook), DEPOSIT);
        s.quote.approve(address(hook), DEPOSIT);
        hook.deposit(DEPOSIT, DEPOSIT);
    }

    function _tokens() internal returns (DemoToken base, DemoToken quote) {
        bytes memory baseInit = abi.encodePacked(type(DemoToken).creationCode, abi.encode("Holster Base", "BASE"));
        bytes memory quoteInit = abi.encodePacked(type(DemoToken).creationCode, abi.encode("Holster USD", "USDC"));
        bytes32 baseSalt = keccak256(abi.encode("holster.base", block.timestamp));
        address baseAddr = vm.computeCreate2Address(baseSalt, keccak256(baseInit));
        uint256 i = block.timestamp;
        while (vm.computeCreate2Address(bytes32(i), keccak256(quoteInit)) <= baseAddr) i++;
        base = DemoToken(_create2(baseSalt, baseInit));
        quote = DemoToken(_create2(bytes32(i), quoteInit));
    }
}
