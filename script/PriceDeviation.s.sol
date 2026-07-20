// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IAggregatorV3} from "../src/oracle/ChainlinkPriceOracle.sol";

/// @notice Read-only helper to size `ChainlinkPriceOracle.maxDeviationBps`. For each pool it compares the
/// live Uniswap V4 spot price (from `PoolManager.getSlot0`) against the price implied by the two Chainlink
/// USD feeds in `script/oracle_feeds.json`, and reports the **basis** in bps. That basis is the structural
/// gap the oracle must tolerate; the guard also has to absorb the pool fee and execution slippage, so the
/// suggested tolerance is `basis + poolFee + BUFFER`.
///
/// The oracle guards an operator swap by requiring `realizedOut >= expectedOut * (1 - maxDeviationBps)`,
/// where `expectedOut` comes from the feeds and `realizedOut` from the pool (net of fee + slippage). So
/// `maxDeviationBps` must exceed `basis + poolFee + slippage`, but stay small enough to still catch a
/// manipulated/adverse swap.
///
/// Reads the PoolManager from `script/chain_params.json` (by `block.chainid`) and the feeds from
/// `script/oracle_feeds.json`. The pools to check come from a config JSON (env `POOLS_CONFIG`, default
/// `script/price_check_pools.example.json`) as PARALLEL ARRAYS; index 0 must be `currency0` (the lower
/// address) so it lines up with the pool's ordering.
///
///   POOLS_CONFIG=script/my_pools.json forge script script/PriceDeviation.s.sol --sig "run()" --rpc-url $RPC
contract PriceDeviation is Script {
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 0x1000000000000000000000000; // 2**96
    uint256 internal constant BUFFER_BPS = 50; // 0.5% safety margin added to the suggestion

    error ChainConfigMissing(uint256 chainId);
    error LengthMismatch();

    struct Pool {
        PoolKey key;
        string sym0;
        string sym1;
        uint8 dec0;
        uint8 dec1;
    }

    function run() external view {
        uint256 chainId = block.chainid;
        IPoolManager pm = _poolManager(chainId);
        string memory feeds = vm.readFile("./script/oracle_feeds.json");
        Pool[] memory pools = _readPools();

        console2.log("== Chainlink vs Uniswap V4 price basis ==");
        console2.log("chainId:", chainId);
        console2.log("PoolManager:", address(pm));
        console2.log("");

        uint256 worstSuggestion;
        for (uint256 i = 0; i < pools.length; ++i) {
            uint256 suggestion = _reportPool(pm, feeds, chainId, pools[i]);
            if (suggestion > worstSuggestion) worstSuggestion = suggestion;
        }

        console2.log("");
        console2.log("Suggested maxDeviationBps (worst pool basis + fee + buffer):", worstSuggestion);
        console2.log("BUFFER_BPS used:", BUFFER_BPS);
    }

    /// @return suggestion basis + poolFee + buffer for this pool (0 if it could not be evaluated).
    function _reportPool(IPoolManager pm, string memory feeds, uint256 chainId, Pool memory p)
        internal
        view
        returns (uint256 suggestion)
    {
        string memory pair = string.concat(p.sym0, "/", p.sym1);
        (uint160 sqrtP,,,) = pm.getSlot0(p.key.toId());
        if (sqrtP == 0) {
            console2.log(string.concat("[", pair, "] pool NOT initialized (check currencies/fee/tickSpacing/hooks)"));
            return 0;
        }

        // Live V4 spot: currency1 per currency0, decimal-adjusted, scaled by WAD.
        uint256 v4 = _v4Price(sqrtP, p.dec0, p.dec1);
        // Chainlink implied: usd0/usd1 (currency1 per currency0), scaled by WAD.
        uint256 cl = _chainlinkPrice(feeds, chainId, p.sym0, p.sym1);
        if (cl == 0) {
            console2.log(string.concat("[", pair, "] missing/zero Chainlink feed for one side; skipped"));
            return 0;
        }

        uint256 basisBps = _absDiffBps(v4, cl);
        uint256 feeBps = uint256(p.key.fee) / 100; // v4 fee is in hundredths of a bip (1e6 = 100%)
        suggestion = basisBps + feeBps + BUFFER_BPS;

        console2.log(string.concat("[", pair, "]"));
        console2.log("  V4 spot (c1/c0, 1e18):    ", v4);
        console2.log("  Chainlink (c1/c0, 1e18):  ", cl);
        console2.log("  basis (bps):              ", basisBps);
        console2.log("  pool fee (bps):           ", feeBps);
        console2.log("  -> min maxDeviationBps:   ", suggestion);
    }

    // ────────── price math ──────────

    /// @dev V4 spot as currency1-per-currency0, decimal-adjusted, scaled by 1e18.
    function _v4Price(uint160 sqrtP, uint8 dec0, uint8 dec1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96); // raw price * 2^96
        return FullMath.mulDiv(priceX96, WAD * (10 ** dec0), Q96 * (10 ** dec1));
    }

    /// @dev Chainlink implied currency1-per-currency0 (= usd0/usd1) scaled by 1e18, using live feed data.
    function _chainlinkPrice(string memory feeds, uint256 chainId, string memory sym0, string memory sym1)
        internal
        view
        returns (uint256)
    {
        (uint256 a0, uint8 fd0) = _readFeed(feeds, chainId, sym0);
        (uint256 a1, uint8 fd1) = _readFeed(feeds, chainId, sym1);
        if (a0 == 0 || a1 == 0) return 0;
        // usd0/usd1 * 1e18 = a0 * 10^fd1 * 1e18 / (a1 * 10^fd0)
        return FullMath.mulDiv(a0, (10 ** fd1) * WAD, a1 * (10 ** fd0));
    }

    /// @dev Live answer + feed decimals for `sym` on `chainId` (0 answer ⇒ missing/stale/non-positive).
    function _readFeed(string memory feeds, uint256 chainId, string memory sym)
        internal
        view
        returns (uint256 answer, uint8 feedDecimals)
    {
        string memory path = string.concat('.["', vm.toString(chainId), '"].', sym, ".aggregator");
        if (!vm.keyExistsJson(feeds, path)) return (0, 0);
        address agg = vm.parseJsonAddress(feeds, path);
        if (agg == address(0)) return (0, 0);
        (, int256 a,,,) = IAggregatorV3(agg).latestRoundData();
        if (a <= 0) return (0, 0);
        return (uint256(a), IAggregatorV3(agg).decimals());
    }

    function _absDiffBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return FullMath.mulDiv(diff, 10_000, b); // relative to the Chainlink reference
    }

    // ────────── config loading ──────────

    function _poolManager(uint256 chainId) internal view returns (IPoolManager) {
        string memory json = vm.readFile("./script/chain_params.json");
        string memory path = string.concat('.["', vm.toString(chainId), '"].poolManager');
        if (!vm.keyExistsJson(json, path)) revert ChainConfigMissing(chainId);
        return IPoolManager(vm.parseJsonAddress(json, path));
    }

    function _readPools() internal view returns (Pool[] memory pools) {
        string memory json = vm.readFile(vm.envOr("POOLS_CONFIG", string("script/price_check_pools.example.json")));
        address[] memory c0 = vm.parseJsonAddressArray(json, ".currency0");
        address[] memory c1 = vm.parseJsonAddressArray(json, ".currency1");
        uint256[] memory fee = vm.parseJsonUintArray(json, ".fee");
        int256[] memory spacing = vm.parseJsonIntArray(json, ".tickSpacing");
        address[] memory hooks = vm.parseJsonAddressArray(json, ".hooks");
        string[] memory sym0 = vm.parseJsonStringArray(json, ".symbol0");
        string[] memory sym1 = vm.parseJsonStringArray(json, ".symbol1");
        uint256[] memory dec0 = vm.parseJsonUintArray(json, ".decimals0");
        uint256[] memory dec1 = vm.parseJsonUintArray(json, ".decimals1");

        uint256 n = c0.length;
        if (
            c1.length != n || fee.length != n || spacing.length != n || hooks.length != n || sym0.length != n
                || sym1.length != n || dec0.length != n || dec1.length != n
        ) revert LengthMismatch();

        pools = new Pool[](n);
        for (uint256 i = 0; i < n; ++i) {
            pools[i] = Pool({
                key: PoolKey({
                    currency0: Currency.wrap(c0[i]),
                    currency1: Currency.wrap(c1[i]),
                    fee: uint24(fee[i]),
                    tickSpacing: int24(spacing[i]),
                    hooks: IHooks(hooks[i])
                }),
                sym0: sym0[i],
                sym1: sym1[i],
                dec0: uint8(dec0[i]),
                dec1: uint8(dec1[i])
            });
        }
    }
}
