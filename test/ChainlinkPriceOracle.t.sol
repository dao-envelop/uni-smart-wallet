// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Mock Chainlink aggregator (`AggregatorV3Interface` subset).
contract MockAggregator {
    uint8 public decimals;
    int256 internal answer;
    uint256 internal updatedAt;

    constructor(uint8 d, int256 a, uint256 t) {
        decimals = d;
        answer = a;
        updatedAt = t;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, updatedAt, 0);
    }
}

/// @notice Reference-oracle behaviour: in-bounds => enforced=true; out-of-bounds => revert; stale /
/// unconfigured => enforced=false (no opinion).
contract ChainlinkPriceOracleTest is Test {
    ChainlinkPriceOracle internal oracle;
    MockAggregator internal feed0; // currency0 = "$2000" asset
    MockAggregator internal feed1; // currency1 = "$1" asset

    Currency internal c0 = Currency.wrap(address(0xA0));
    Currency internal c1 = Currency.wrap(address(0xB0));
    PoolKey internal key;

    uint32 internal constant HEARTBEAT = 3600;
    uint16 internal constant MAX_DEV_BPS = 100; // 1%

    function setUp() public {
        vm.warp(100_000);
        feed0 = new MockAggregator(8, int256(2000e8), block.timestamp);
        feed1 = new MockAggregator(8, int256(1e8), block.timestamp);

        oracle = new ChainlinkPriceOracle(address(this), MAX_DEV_BPS);
        oracle.setFeed(c0, address(feed0), HEARTBEAT, 18);
        oracle.setFeed(c1, address(feed1), HEARTBEAT, 18);

        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    // Swap zeroForOne: 1 unit of c0 ($2000) → fair 2000 units of c1 ($1).
    function test_inBounds_enforcedTrue() public view {
        assertTrue(oracle.check(key, true, 1e18, 2000e18), "exact fair price enforced");
        assertTrue(oracle.check(key, true, 1e18, 1985e18), "within 1% tolerance enforced");
    }

    function test_outOfBounds_reverts() public {
        // 1980e18 is the floor (2000 * 99%); below it must revert.
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.PriceOutOfBounds.selector, 1979e18, 1980e18));
        oracle.check(key, true, 1e18, 1979e18);
    }

    function test_reverseDirection_inBounds() public view {
        // oneForZero: 2000 units of c1 → fair 1 unit of c0.
        assertTrue(oracle.check(key, false, 2000e18, 1e18), "reverse direction fair price enforced");
    }

    function test_staleFeed_notEnforced() public {
        feed0.set(int256(2000e8), block.timestamp - HEARTBEAT - 1); // older than heartbeat
        assertFalse(oracle.check(key, true, 1e18, 2000e18), "stale reference => no opinion");
    }

    function test_unconfiguredCurrency_notEnforced() public view {
        PoolKey memory k2 = key;
        k2.currency1 = Currency.wrap(address(0xCC)); // no feed
        assertFalse(oracle.check(k2, true, 1e18, 2000e18), "missing feed => no opinion");
    }

    function test_nonPositiveAnswer_notEnforced() public {
        feed1.set(int256(0), block.timestamp);
        assertFalse(oracle.check(key, true, 1e18, 2000e18), "zero answer => no opinion");
    }
}
