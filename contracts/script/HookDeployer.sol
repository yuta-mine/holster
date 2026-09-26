// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice CREATE2 helpers shared by the v4 deploy scripts.
abstract contract HookDeployer is Script {
    /// @dev Deploys through the deterministic CREATE2 factory, so the address is the one computed beforehand.
    function _create2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        address expected = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == expected, "create2 failed");
        deployed = expected;
    }

    /// @dev The first salt whose address carries the hook's permission flags and is still free, so running the
    ///      same deploy again gives a new hook.
    function _mineSalt(bytes32 initCodeHash) internal view returns (bytes32 salt) {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        for (uint256 i; i < 1_000_000; i++) {
            address a = vm.computeCreate2Address(bytes32(i), initCodeHash, CREATE2_FACTORY);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && a.code.length == 0) return bytes32(i);
        }
        revert("salt not found");
    }
}
