// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HolsterHook} from "../src/HolsterHook.sol";
import {DemoToken} from "./DemoToken.sol";
import {DemoRouter} from "./DemoRouter.sol";

/// @notice Deploys the Holster hook on Uniswap v4 with demo tokens.
///
/// Base Sepolia (uses the official PoolManager):
///   forge script script/DeployV4.s.sol --rpc-url base_sepolia --account <keystore> --broadcast
/// Anywhere without a PoolManager (e.g. a local anvil), one is deployed first.
///
/// Parameters (env, optional): TWAP_CANDLES=30 WIDTH_BPS=1000 UPPER_BPS=500 LOWER_BPS=500 DEPLOY_BPS=7500
contract DeployV4 is Script {
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    uint160 constant SQRT_PRICE_1 = 1 << 96;
    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant BACKGROUND_LIQUIDITY = 200_000e18;

    function run() external {
        uint256 candles = vm.envOr("TWAP_CANDLES", uint256(30));
        uint256 width = vm.envOr("WIDTH_BPS", uint256(1000));
        uint256 upper = vm.envOr("UPPER_BPS", uint256(500));
        uint256 lower = vm.envOr("LOWER_BPS", uint256(500));
        uint256 deployBps = vm.envOr("DEPLOY_BPS", uint256(7_500));

        vm.startBroadcast();
        (, address me,) = vm.readCallers();

        IPoolManager manager = IPoolManager(vm.envOr("POOL_MANAGER", BASE_SEPOLIA_POOL_MANAGER));
        if (address(manager).code.length == 0) manager = new PoolManager(me);

        // Demo tokens, deployed so that BASE is currency0 and USDC is currency1.
        (DemoToken base, DemoToken quote) = _tokens();

        // The hook address must carry the permission flags, so the salt is mined.
        bytes memory initCode = abi.encodePacked(
            type(HolsterHook).creationCode, abi.encode(manager, me, candles, width, upper, lower, deployBps)
        );
        HolsterHook hook = HolsterHook(_create2(_mineSalt(keccak256(initCode)), initCode));

        PoolKey memory key = PoolKey(
            Currency.wrap(address(base)), Currency.wrap(address(quote)), 3000, 10, IHooks(address(hook))
        );
        manager.initialize(key, SQRT_PRICE_1);

        // Another LP, so the pool has liquidity beyond Holster (about ±45% around 1.00).
        DemoRouter router = new DemoRouter(manager);
        base.mint(me, 1_000_000e18);
        quote.mint(me, 1_000_000e18);
        base.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        router.addLiquidity(key, -6000, 6000, BACKGROUND_LIQUIDITY);

        // The LP deposits 10,000 BASE + 10,000 USDC into the hook.
        base.approve(address(hook), DEPOSIT);
        quote.approve(address(hook), DEPOSIT);
        hook.deposit(DEPOSIT, DEPOSIT);
        vm.stopBroadcast();

        string memory o = "v4";
        vm.serializeAddress(o, "poolManager", address(manager));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "base", address(base));
        string memory json = vm.serializeAddress(o, "quote", address(quote));
        vm.writeJson(json, string.concat("deployments/v4-", vm.toString(block.chainid), ".json"));

        console.log("PoolManager", address(manager));
        console.log("HolsterHook", address(hook));
        console.log("DemoRouter ", address(router));
        console.log("BASE       ", address(base));
        console.log("USDC       ", address(quote));
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

    /// @dev Deploys through the deterministic CREATE2 factory, so the address is the one computed beforehand.
    function _create2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        address expected = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == expected, "create2 failed");
        deployed = expected;
    }

    function _mineSalt(bytes32 initCodeHash) internal pure returns (bytes32 salt) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        for (uint256 i; i < 1_000_000; i++) {
            address a = vm.computeCreate2Address(bytes32(i), initCodeHash, CREATE2_FACTORY);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags) return bytes32(i);
        }
        revert("salt not found");
    }
}
