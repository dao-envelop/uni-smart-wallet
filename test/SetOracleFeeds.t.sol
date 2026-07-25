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

    function test_resolve_revertsOnUnknownSymbol() public {
        SetOracleFeeds.TokenFeed[] memory tokens = new SetOracleFeeds.TokenFeed[](1);
        tokens[0] = SetOracleFeeds.TokenFeed({token: address(0xDEAD), symbol: "NOPE", decimals: 18});

        vm.expectRevert(abi.encodeWithSelector(SetOracleFeeds.FeedMissing.selector, uint256(42161), "NOPE"));
        script.resolve(42161, tokens);
    }
}
