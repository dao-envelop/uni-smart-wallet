// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";

/// @notice Clones one LP manager (Stable or Volatile) via the universal `LPManagerFactory` from a
/// pool-config JSON.
///
/// The factory address and the product implementations are read from `deployments/<chainId>.json`
/// (written by DeployStableLP): `.factory`, `.impl` (stable), `.volatileImpl`. The config JSON
/// (env `MANAGER_CONFIG`, default `script/manager_config.example.json`) selects the product via
/// `.product` ("stable" | "volatile"; default "stable") and lists pools as PARALLEL ARRAYS (so we avoid
/// forge's alphabetical struct-decode key ordering). Volatile configs omit `.tickLower`/`.tickUpper`
/// (ranges are per-call). Every array must have the same length.
///
///   MANAGER_CONFIG=script/my_pools.json forge script script/CreateManager.s.sol \
///     --rpc-url $RPC --sender $SENDER --account $KEYSTORE --broadcast
contract CreateManager is Script {
    error LengthMismatch();
    error NoPools();
    error NameTooLong(uint256 length);

    function run() external returns (address manager) {
        uint256 chainId = block.chainid;
        address factory = _readFactory(chainId);
        string memory json = vm.readFile(vm.envOr("MANAGER_CONFIG", string("script/manager_config.example.json")));

        bool isVolatile = vm.keyExistsJson(json, ".product")
            && keccak256(bytes(vm.parseJsonString(json, ".product"))) == keccak256(bytes("volatile"));

        address owner = vm.parseJsonAddress(json, ".owner");
        bytes32 name = _readName(json, isVolatile);
        // Default the tokenURI renderer to the chain's deployed descriptor (config `.descriptor`
        // overrides). Wired at init so the clone renders `tokenURI` without a follow-up owner call.
        address descriptor =
            vm.keyExistsJson(json, ".descriptor") ? vm.parseJsonAddress(json, ".descriptor") : _readDescriptor(chainId);

        (address impl, bytes memory initData, uint256 poolCount) = isVolatile
            ? _volatileInit(json, chainId, owner, name, descriptor)
            : _stableInit(json, chainId, owner, name, descriptor);

        vm.startBroadcast();
        manager = LPManagerFactory(factory).createManager(impl, owner, initData);
        vm.stopBroadcast();

        console2.log("Manager created:", manager);
        console2.log("Product:        ", isVolatile ? "volatile" : "stable");
        console2.log("Owner:          ", owner);
        console2.log("Pools:          ", poolCount);
        console2.log("Factory:        ", factory);
    }

    // ────────── per-product init encoding ──────────

    function _stableInit(string memory json, uint256 chainId, address owner, bytes32 name, address descriptor)
        internal
        view
        returns (address impl, bytes memory initData, uint256 poolCount)
    {
        impl = _readImpl(chainId, ".impl");
        (PoolKey[] memory keys, int256[] memory lower, int256[] memory upper) = _parseStablePools(json);
        poolCount = keys.length;

        StableLPManager.StablePoolInit[] memory pools = new StableLPManager.StablePoolInit[](poolCount);
        for (uint256 i = 0; i < poolCount; ++i) {
            pools[i] =
                StableLPManager.StablePoolInit({key: keys[i], tickLower: int24(lower[i]), tickUpper: int24(upper[i])});
        }
        StableLPManager.InitParams memory p =
            StableLPManager.InitParams({owner: owner, name: name, descriptor: descriptor, pools: pools});
        initData = abi.encodeCall(StableLPManager.initialize, (p));
    }

    function _volatileInit(string memory json, uint256 chainId, address owner, bytes32 name, address descriptor)
        internal
        view
        returns (address impl, bytes memory initData, uint256 poolCount)
    {
        impl = _readImpl(chainId, ".volatileImpl");
        PoolKey[] memory keys = _parseKeys(json);
        poolCount = keys.length;
        VolatileLPManager.InitParams memory p =
            VolatileLPManager.InitParams({owner: owner, name: name, descriptor: descriptor, pools: keys});
        initData = abi.encodeCall(VolatileLPManager.initialize, (p));
    }

    // ────────── JSON parsing ──────────

    /// @dev Parse the shared pool-key parallel arrays (currency0/1, fee, tickSpacing, hooks).
    function _parseKeys(string memory json) internal pure returns (PoolKey[] memory keys) {
        address[] memory c0 = vm.parseJsonAddressArray(json, ".currency0");
        address[] memory c1 = vm.parseJsonAddressArray(json, ".currency1");
        uint256[] memory fee = vm.parseJsonUintArray(json, ".fee");
        int256[] memory spacing = vm.parseJsonIntArray(json, ".tickSpacing");
        address[] memory hooks = vm.parseJsonAddressArray(json, ".hooks");

        uint256 n = c0.length;
        if (n == 0) revert NoPools();
        if (c1.length != n || fee.length != n || spacing.length != n || hooks.length != n) revert LengthMismatch();

        keys = new PoolKey[](n);
        for (uint256 i = 0; i < n; ++i) {
            keys[i] = PoolKey({
                currency0: Currency.wrap(c0[i]),
                currency1: Currency.wrap(c1[i]),
                fee: uint24(fee[i]),
                tickSpacing: int24(spacing[i]),
                hooks: IHooks(hooks[i])
            });
        }
    }

    /// @dev Stable configs additionally carry per-pool ranges (`tickLower`/`tickUpper`).
    function _parseStablePools(string memory json)
        internal
        pure
        returns (PoolKey[] memory keys, int256[] memory lower, int256[] memory upper)
    {
        keys = _parseKeys(json);
        lower = vm.parseJsonIntArray(json, ".tickLower");
        upper = vm.parseJsonIntArray(json, ".tickUpper");
        if (lower.length != keys.length || upper.length != keys.length) revert LengthMismatch();
    }

    function _readName(string memory json, bool isVolatile) internal view returns (bytes32) {
        if (vm.keyExistsJson(json, ".name")) return _packName(vm.parseJsonString(json, ".name"));
        return isVolatile ? bytes32("Envelop VolatileLP") : bytes32("Envelop StableLP");
    }

    // ────────── deployments JSON lookups ──────────

    function _readFactory(uint256 chainId) internal view returns (address) {
        return vm.parseJsonAddress(_deployments(chainId), ".factory");
    }

    function _readImpl(uint256 chainId, string memory key) internal view returns (address) {
        return vm.parseJsonAddress(_deployments(chainId), key);
    }

    /// @dev The chain's deployed descriptor (`.descriptor` in the deployments file), or zero if absent.
    function _readDescriptor(uint256 chainId) internal view returns (address) {
        string memory json = _deployments(chainId);
        return vm.keyExistsJson(json, ".descriptor") ? vm.parseJsonAddress(json, ".descriptor") : address(0);
    }

    function _deployments(uint256 chainId) internal view returns (string memory) {
        return vm.readFile(string.concat("./deployments/", vm.toString(chainId), ".json"));
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
