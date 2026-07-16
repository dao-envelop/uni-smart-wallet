// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";

/// @notice Clones one StableLPManager via the factory from a pool-config JSON.
///
/// The factory address is read from `deployments/<chainId>.json` (written by DeployStableLP).
/// The pool set comes from a config JSON (env `MANAGER_CONFIG`, default
/// `script/manager_config.example.json`), using PARALLEL ARRAYS so we avoid forge's
/// alphabetical struct-decode key ordering. Every array must have the same length.
///
///   MANAGER_CONFIG=script/my_pools.json forge script script/CreateManager.s.sol \
///     --rpc-url $RPC --sender $SENDER --account $KEYSTORE --broadcast
contract CreateManager is Script {
    error LengthMismatch();
    error NoPools();
    error NameTooLong(uint256 length);

    function run() external returns (address manager) {
        address factory = _readFactory(block.chainid);
        string memory cfgPath = vm.envOr("MANAGER_CONFIG", string("script/manager_config.example.json"));
        BaseLPManager.InitParams memory p = _parseConfig(vm.readFile(cfgPath));

        vm.startBroadcast();
        manager = StableLPFactory(factory).createManager(p);
        vm.stopBroadcast();

        console2.log("Manager created:", manager);
        console2.log("Owner:          ", p.owner);
        console2.log("Pools:          ", p.pools.length);
        console2.log("Factory:        ", factory);
    }

    function _readFactory(uint256 chainId) internal view returns (address) {
        string memory json = vm.readFile(string.concat("./deployments/", vm.toString(chainId), ".json"));
        return vm.parseJsonAddress(json, ".factory");
    }

    function _parseConfig(string memory json) internal view returns (BaseLPManager.InitParams memory p) {
        p.owner = vm.parseJsonAddress(json, ".owner");
        // Optional NFT name (≤31 chars), packed into bytes32; defaults to the shared brand name.
        p.name = vm.keyExistsJson(json, ".name")
            ? _packName(vm.parseJsonString(json, ".name"))
            : bytes32("Envelop StableLP");

        address[] memory c0 = vm.parseJsonAddressArray(json, ".currency0");
        address[] memory c1 = vm.parseJsonAddressArray(json, ".currency1");
        uint256[] memory fee = vm.parseJsonUintArray(json, ".fee");
        int256[] memory spacing = vm.parseJsonIntArray(json, ".tickSpacing");
        address[] memory hooks = vm.parseJsonAddressArray(json, ".hooks");
        int256[] memory lower = vm.parseJsonIntArray(json, ".tickLower");
        int256[] memory upper = vm.parseJsonIntArray(json, ".tickUpper");

        uint256 n = c0.length;
        if (n == 0) revert NoPools();
        if (
            c1.length != n || fee.length != n || spacing.length != n || hooks.length != n || lower.length != n
                || upper.length != n
        ) revert LengthMismatch();

        p.pools = new BaseLPManager.PoolConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            p.pools[i] = BaseLPManager.PoolConfig({
                key: PoolKey({
                    currency0: Currency.wrap(c0[i]),
                    currency1: Currency.wrap(c1[i]),
                    fee: uint24(fee[i]),
                    tickSpacing: int24(spacing[i]),
                    hooks: IHooks(hooks[i])
                }),
                tickLower: int24(lower[i]),
                tickUpper: int24(upper[i])
            });
        }
    }

    /// @dev Left-align ≤31 ASCII chars into a bytes32 (matches the manager's `name()` decode).
    function _packName(string memory s) internal pure returns (bytes32 r) {
        bytes memory b = bytes(s);
        if (b.length > 31) revert NameTooLong(b.length);
        for (uint256 i = 0; i < b.length; ++i) {
            r |= bytes32(uint256(uint8(b[i])) << (8 * (31 - i)));
        }
    }
}
