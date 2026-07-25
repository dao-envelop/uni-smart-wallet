// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";

/// @notice Populate a deployed {ChainlinkPriceOracle} with the per-currency Chainlink USD feeds it needs.
/// {DeployStableLP} only *deploys* the oracle (constructor: tolerance + sequencer gate); an oracle with no
/// feeds has no opinion, so `check` returns false and every **operator** swap fails closed
/// (`OperatorSwapUnverified`). This script is the missing wiring step, and it is idempotent: a currency
/// whose stored feed already matches the config is skipped, so re-running costs nothing.
///
/// Inputs:
/// - The oracle address: env `ORACLE`, else `.oracle` from `deployments/<chainId>.json`.
/// - The currencies to wire: env `TOKENS_CONFIG`, else `script/oracle_tokens/<chainId>.json` — PARALLEL
///   ARRAYS `token` / `symbol` / `decimals`, where `symbol` is a key in the feeds file and `decimals` is
///   the ERC-20 decimals of the token itself (18 for native ETH, i.e. `token` = address(0)).
/// - The feeds: env `FEEDS_CONFIG`, else `script/oracle_feeds.json`, keyed by chainId then symbol
///   (`aggregator` + `heartbeat`). `feedDecimals` is not passed — {ChainlinkPriceOracle.setFeed} caches it
///   from the aggregator itself.
///
/// The broadcaster MUST be the oracle owner (`setFeed` is owner-only); the run reverts early otherwise.
///
///   forge script script/SetOracleFeeds.s.sol --rpc-url $RPC --sender $SENDER --account $KEYSTORE --broadcast
///
/// Omit `--broadcast` for a dry run: the plan is printed either way.
contract SetOracleFeeds is Script {
    /// @param token The currency being wired (address(0) = native).
    /// @param symbol Key into the feeds file (e.g. "ETH", "USDC", "WBTC").
    /// @param decimals The token's own ERC-20 decimals (18 for native).
    struct TokenFeed {
        address token;
        string symbol;
        uint8 decimals;
    }

    /// @param token Currency the feed is registered under.
    /// @param aggregator Chainlink USD aggregator resolved from the feeds file.
    /// @param heartbeat Max accepted answer age, seconds.
    /// @param decimals The token's own ERC-20 decimals.
    struct ResolvedFeed {
        address token;
        address aggregator;
        uint32 heartbeat;
        uint8 decimals;
    }

    error OracleMissing(uint256 chainId);
    error TokensConfigMissing(string path);
    error LengthMismatch();
    error FeedMissing(uint256 chainId, string symbol);
    error NotOracleOwner(address owner, address sender);

    function run() external {
        uint256 chainId = block.chainid;
        ChainlinkPriceOracle oracle = ChainlinkPriceOracle(_oracleAddress(chainId));
        ResolvedFeed[] memory resolved = _resolve(chainId, _readTokens(chainId));

        address owner = oracle.owner();
        if (owner != msg.sender) revert NotOracleOwner(owner, msg.sender);

        console2.log("== SetOracleFeeds ==");
        console2.log("chainId:", chainId);
        console2.log("oracle:", address(oracle));

        vm.startBroadcast();
        uint256 written = applyFeeds(oracle, resolved);
        vm.stopBroadcast();

        console2.log("feeds written:", written);
        console2.log("feeds already current:", resolved.length - written);
    }

    /// @notice Write every feed whose stored entry differs from `resolved`. Filesystem-free so tests can
    /// drive it directly.
    /// @param oracle The oracle to configure; the caller must be its owner.
    /// @param resolved The desired per-currency feed configuration.
    /// @return written Number of `setFeed` calls actually made (unchanged entries are skipped).
    function applyFeeds(ChainlinkPriceOracle oracle, ResolvedFeed[] memory resolved) public returns (uint256 written) {
        for (uint256 i = 0; i < resolved.length; ++i) {
            ResolvedFeed memory f = resolved[i];
            Currency currency = Currency.wrap(f.token);
            (address agg, uint32 heartbeat,, uint8 tokenDecimals) = oracle.feeds(currency);
            if (agg == f.aggregator && heartbeat == f.heartbeat && tokenDecimals == f.decimals) {
                console2.log("  skip (current):", f.token, agg);
                continue;
            }
            oracle.setFeed(currency, f.aggregator, f.heartbeat, f.decimals);
            console2.log("  setFeed:", f.token, f.aggregator);
            ++written;
        }
    }

    // ────────── config loading ──────────

    /// @dev Env `ORACLE` wins; otherwise `.oracle` from `deployments/<chainId>.json`.
    function _oracleAddress(uint256 chainId) internal view returns (address oracle) {
        oracle = vm.envOr("ORACLE", address(0));
        if (oracle != address(0)) return oracle;

        string memory path = string.concat("./deployments/", vm.toString(chainId), ".json");
        if (vm.exists(path)) {
            string memory json = vm.readFile(path);
            if (vm.keyExistsJson(json, ".oracle")) oracle = vm.parseJsonAddress(json, ".oracle");
        }
        if (oracle == address(0)) revert OracleMissing(chainId);
    }

    /// @dev Currencies to wire, from `TOKENS_CONFIG` or `script/oracle_tokens/<chainId>.json`.
    function _readTokens(uint256 chainId) internal view returns (TokenFeed[] memory tokens) {
        string memory path =
            vm.envOr("TOKENS_CONFIG", string.concat("script/oracle_tokens/", vm.toString(chainId), ".json"));
        if (!vm.exists(path)) revert TokensConfigMissing(path);
        return readTokens(path);
    }

    /// @notice Parse a tokens config (parallel arrays). Public so tests can drive it on a fixture.
    /// @param path Path to the JSON config.
    /// @return tokens The parsed currency list.
    function readTokens(string memory path) public view returns (TokenFeed[] memory tokens) {
        string memory json = vm.readFile(path);
        address[] memory addrs = vm.parseJsonAddressArray(json, ".token");
        string[] memory symbols = vm.parseJsonStringArray(json, ".symbol");
        uint256[] memory decimals = vm.parseJsonUintArray(json, ".decimals");
        if (symbols.length != addrs.length || decimals.length != addrs.length) revert LengthMismatch();

        tokens = new TokenFeed[](addrs.length);
        for (uint256 i = 0; i < addrs.length; ++i) {
            tokens[i] = TokenFeed({token: addrs[i], symbol: symbols[i], decimals: uint8(decimals[i])});
        }
    }

    /// @notice Resolve each currency's aggregator + heartbeat from the feeds file. Reverts on a symbol the
    /// chain has no feed for — a silently skipped currency would leave operator swaps failing closed.
    /// @param chainId Chain whose feed block to read.
    /// @param tokens Currencies to resolve.
    /// @return resolved Ready-to-write feed entries, one per input token.
    function _resolve(uint256 chainId, TokenFeed[] memory tokens)
        internal
        view
        returns (ResolvedFeed[] memory resolved)
    {
        string memory feeds = vm.readFile(vm.envOr("FEEDS_CONFIG", string("./script/oracle_feeds.json")));
        resolved = new ResolvedFeed[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
            string memory base = string.concat('.["', vm.toString(chainId), '"].', tokens[i].symbol);
            string memory aggPath = string.concat(base, ".aggregator");
            if (!vm.keyExistsJson(feeds, aggPath)) revert FeedMissing(chainId, tokens[i].symbol);

            address agg = vm.parseJsonAddress(feeds, aggPath);
            if (agg == address(0)) revert FeedMissing(chainId, tokens[i].symbol);

            resolved[i] = ResolvedFeed({
                token: tokens[i].token,
                aggregator: agg,
                heartbeat: uint32(vm.parseJsonUint(feeds, string.concat(base, ".heartbeat"))),
                decimals: tokens[i].decimals
            });
        }
    }
}
