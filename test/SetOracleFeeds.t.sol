// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SetOracleFeeds} from "../script/SetOracleFeeds.s.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Exposes the script's internal feed resolution so the shipped configs can be checked.
contract SetOracleFeedsHarness is SetOracleFeeds {
    function resolve(uint256 chainId, TokenFeed[] memory tokens) external view returns (ResolvedFeed[] memory) {
        return _resolve(chainId, tokens);
    }
}

/// @notice Covers the oracle-feed wiring script: idempotent writes, and that the shipped
/// `script/oracle_tokens/*.json` configs resolve against `script/oracle_feeds.json`.
contract SetOracleFeedsTest is Test {
    SetOracleFeedsHarness internal script;
    ChainlinkPriceOracle internal oracle;
    MockAggregator internal ethFeed;
    MockAggregator internal usdcFeed;

    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function setUp() public {
        script = new SetOracleFeedsHarness();
        // The script is the broadcaster in production; here it must own the oracle to call setFeed.
        oracle = new ChainlinkPriceOracle(address(script), 100, address(0), 3600);
        ethFeed = new MockAggregator(8, int256(1860e8), block.timestamp);
        usdcFeed = new MockAggregator(8, int256(1e8), block.timestamp);
    }

    function _twoFeeds() internal view returns (SetOracleFeeds.ResolvedFeed[] memory r) {
        r = new SetOracleFeeds.ResolvedFeed[](2);
        r[0] = SetOracleFeeds.ResolvedFeed({
            token: address(0), aggregator: address(ethFeed), heartbeat: 1755, decimals: 18
        });
        r[1] = SetOracleFeeds.ResolvedFeed({token: USDC, aggregator: address(usdcFeed), heartbeat: 255, decimals: 6});
    }

    function test_applyFeeds_writesEveryCurrency() public {
        assertEq(script.applyFeeds(oracle, _twoFeeds()), 2, "both feeds written");

        (address agg, uint32 heartbeat, uint8 feedDecimals, uint8 tokenDecimals) =
            oracle.feeds(Currency.wrap(address(0)));
        assertEq(agg, address(ethFeed), "native aggregator");
        assertEq(heartbeat, 1755, "native heartbeat");
        assertEq(feedDecimals, 8, "feedDecimals cached from the aggregator");
        assertEq(tokenDecimals, 18, "native token decimals");

        (agg, heartbeat,, tokenDecimals) = oracle.feeds(Currency.wrap(USDC));
        assertEq(agg, address(usdcFeed), "usdc aggregator");
        assertEq(heartbeat, 255, "usdc heartbeat");
        assertEq(tokenDecimals, 6, "usdc token decimals");
    }

    function test_applyFeeds_isIdempotent() public {
        script.applyFeeds(oracle, _twoFeeds());
        assertEq(script.applyFeeds(oracle, _twoFeeds()), 0, "second run writes nothing");
    }

    function test_applyFeeds_rewritesChangedEntry() public {
        script.applyFeeds(oracle, _twoFeeds());

        SetOracleFeeds.ResolvedFeed[] memory changed = _twoFeeds();
        changed[1].heartbeat = 3600;
        assertEq(script.applyFeeds(oracle, changed), 1, "only the changed entry is rewritten");

        (, uint32 heartbeat,,) = oracle.feeds(Currency.wrap(USDC));
        assertEq(heartbeat, 3600, "heartbeat updated");
    }

    function test_readTokens_parsesShippedArbitrumConfig() public view {
        SetOracleFeeds.TokenFeed[] memory tokens = script.readTokens("script/oracle_tokens/42161.json");
        assertEq(tokens.length, 6, "arbitrum currency count");
        assertEq(tokens[0].token, address(0), "index 0 is native ETH");
        assertEq(tokens[0].decimals, 18, "native decimals");
        assertEq(tokens[1].token, USDC, "index 1 is USDC");
        assertEq(tokens[1].decimals, 6, "usdc decimals");
    }

    /// @dev Every shipped config must resolve — a symbol the chain has no feed for would only surface at
    /// broadcast time otherwise.
    function test_shippedConfigsResolveAgainstFeedsFile() public view {
        uint256[4] memory chains = [uint256(1), 130, 8453, 42161];
        for (uint256 i = 0; i < chains.length; ++i) {
            string memory path = string.concat("script/oracle_tokens/", vm.toString(chains[i]), ".json");
            SetOracleFeeds.TokenFeed[] memory tokens = script.readTokens(path);
            assertGt(tokens.length, 0, "config not empty");

            SetOracleFeeds.ResolvedFeed[] memory resolved = script.resolve(chains[i], tokens);
            for (uint256 j = 0; j < resolved.length; ++j) {
                assertTrue(resolved[j].aggregator != address(0), "aggregator resolved");
                assertGt(resolved[j].heartbeat, 0, "heartbeat resolved");
                assertEq(resolved[j].token, tokens[j].token, "token preserved");
            }
        }
    }

    /// @dev The staleness bound written on-chain must be the published Chainlink heartbeat *padded*:
    /// `updatedAt` trails the round-trigger interval by the round + inclusion lag, so a bound equal to the
    /// published heartbeat is unreachable — any feed that actually reaches its heartbeat reads stale and
    /// closes the fail-closed operator gate (task_045: Arbitrum USDC published 255s, cadence 270s).
    /// Walks the feeds file itself rather than the token configs, so a network added with a raw directory
    /// value fails here even before any token is wired to it.
    function test_shippedFeeds_heartbeatIsPaddedPublished() public view {
        string memory feeds = vm.readFile("script/oracle_feeds.json");
        string[] memory chains = vm.parseJsonKeys(feeds, ".");

        uint256 chainsChecked;
        for (uint256 i = 0; i < chains.length; ++i) {
            if (_isMetadataKey(chains[i])) continue;
            string memory chainPath = string.concat('.["', chains[i], '"]');
            string[] memory symbols = vm.parseJsonKeys(feeds, chainPath);

            uint256 feedsChecked;
            for (uint256 j = 0; j < symbols.length; ++j) {
                if (_isMetadataKey(symbols[j])) continue;
                string memory base = string.concat(chainPath, ".", symbols[j]);
                string memory where = string.concat(chains[i], ".", symbols[j]);

                uint256 published = vm.parseJsonUint(feeds, string.concat(base, ".publishedHeartbeat"));
                uint256 heartbeat = vm.parseJsonUint(feeds, string.concat(base, ".heartbeat"));
                assertGt(published, 0, string.concat("publishedHeartbeat missing: ", where));
                assertEq(heartbeat, _pad(published), string.concat("heartbeat not padded: ", where));
                ++feedsChecked;
            }
            assertGt(feedsChecked, 0, string.concat("no feeds walked for chain ", chains[i]));
            ++chainsChecked;
        }
        assertGt(chainsChecked, 0, "no chains walked");
    }

    /// @dev The padding rule, mirrored from `script/oracle_feeds.json`. The cap keeps the long-heartbeat
    /// feeds near 24h — a wider staleness window makes the guard more permissive, so the bound is only
    /// loosened where it was actually tight.
    function _pad(uint256 published) internal pure returns (uint256) {
        uint256 slack = 2 * published;
        return published + (slack < 900 ? slack : 900);
    }

    /// @dev `_comment` / `_name` / `_note` are documentation keys, not feeds.
    function _isMetadataKey(string memory key) internal pure returns (bool) {
        bytes memory b = bytes(key);
        return b.length > 0 && b[0] == "_";
    }

    function test_resolve_revertsOnUnknownSymbol() public {
        SetOracleFeeds.TokenFeed[] memory tokens = new SetOracleFeeds.TokenFeed[](1);
        tokens[0] = SetOracleFeeds.TokenFeed({token: address(0xDEAD), symbol: "NOPE", decimals: 18});

        vm.expectRevert(abi.encodeWithSelector(SetOracleFeeds.FeedMissing.selector, uint256(42161), "NOPE"));
        script.resolve(42161, tokens);
    }
}
