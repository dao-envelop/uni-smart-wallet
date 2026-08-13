// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {UniLens} from "../src/UniLens.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockPriceOracle} from "./helpers/Mocks.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice The read paths added in #42: on-chain operator enumeration (`operatorCount`/`operatorList`,
/// aggregated by `UniLens.operators`), the stable position-bounds getter, and the one-call operator-swap
/// guard status. Each replaces an off-chain workaround (log folding / calldata archaeology / a 4-deep
/// dependent read chain), so the tests assert parity with the underlying source of truth.
contract UniLensOperatorsOracleTest is StableLPTestBase {
    UniLens internal lens;
    address internal newOwner = address(0xA11CE2);

    address internal opA = address(0xA1);
    address internal opB = address(0xB2);
    address internal opC = address(0xC3);

    function setUp() public override {
        super.setUp();
        lens = new UniLens();
    }

    // ────────── operator enumeration ──────────

    function test_operatorEnumeration_emptyByDefault() public view {
        assertEq(mgr.operatorCount(), 0, "no operators at init");
        assertEq(lens.operators(address(mgr)).length, 0, "lens agrees");
    }

    function test_operatorEnumeration_matchesOperatorsMapping() public {
        vm.startPrank(owner);
        mgr.setOperator(opA, true);
        mgr.setOperator(opB, true);
        mgr.setOperator(opC, true);
        vm.stopPrank();

        assertEq(mgr.operatorCount(), 3, "count");
        address[] memory ops = lens.operators(address(mgr));
        assertEq(ops.length, 3, "lens count");
        // Every enumerated address must be authorized, and the enumeration must be duplicate-free.
        for (uint256 i = 0; i < ops.length; ++i) {
            assertTrue(mgr.operators(ops[i]), "enumerated => authorized");
            assertEq(ops[i], mgr.operatorList(i), "lens mirrors operatorList(i)");
            for (uint256 j = i + 1; j < ops.length; ++j) {
                assertTrue(ops[i] != ops[j], "no duplicates");
            }
        }
    }

    function test_operatorEnumeration_spliceOnDisable_dropsOnlyThatOperator() public {
        vm.startPrank(owner);
        mgr.setOperator(opA, true);
        mgr.setOperator(opB, true);
        mgr.setOperator(opC, true);
        mgr.setOperator(opB, false); // swap-and-pop: order is NOT preserved, membership is
        vm.stopPrank();

        address[] memory ops = lens.operators(address(mgr));
        assertEq(ops.length, 2, "one spliced out");
        bool sawA;
        bool sawC;
        for (uint256 i = 0; i < ops.length; ++i) {
            assertTrue(ops[i] != opB, "disabled operator is gone");
            if (ops[i] == opA) sawA = true;
            if (ops[i] == opC) sawC = true;
        }
        assertTrue(sawA && sawC, "the other two survive");
    }

    function test_operatorEnumeration_reEnableChurn_staysCompact() public {
        // The list must track the LIVE set, not historical churn — otherwise the per-transfer clear
        // loop grows unboundedly (the bug the splice fixed) and enumeration would report stale entries.
        vm.startPrank(owner);
        for (uint256 i = 0; i < 50; ++i) {
            mgr.setOperator(bot, true);
            mgr.setOperator(bot, false);
        }
        mgr.setOperator(bot, true);
        vm.stopPrank();

        assertEq(mgr.operatorCount(), 1, "compact despite 50 enable/disable cycles");
        address[] memory ops = lens.operators(address(mgr));
        assertEq(ops.length, 1, "lens count");
        assertEq(ops[0], bot, "the one live operator");
    }

    function test_operatorEnumeration_clearedOnOwnershipTransfer() public {
        vm.startPrank(owner);
        mgr.setOperator(opA, true);
        mgr.setOperator(opC, true);
        mgr.transferFrom(owner, newOwner, mgr.TOKEN_ID());
        vm.stopPrank();

        assertEq(mgr.operatorCount(), 0, "auto-cleared on transfer");
        assertEq(lens.operators(address(mgr)).length, 0, "lens agrees");
        assertFalse(mgr.operators(opA));
        assertFalse(mgr.operators(opC));
    }

    function test_operatorList_outOfRangeIndex_reverts() public {
        vm.expectRevert();
        mgr.operatorList(0);
    }

    // ────────── stable position bounds (one position per pool, fixed at initialize) ──────────

    function test_stableRanges_matchInitParams() public view {
        UniLens.StableRange[] memory ranges = lens.stableRanges(address(mgr));
        assertEq(ranges.length, mgr.poolCount(), "one per configured pool");
        assertEq(ranges.length, 3, "3 pools");
        for (uint256 i = 0; i < ranges.length; ++i) {
            PoolKey memory key = mgr.pools(i);
            assertEq(PoolId.unwrap(ranges[i].poolId), PoolId.unwrap(key.toId()), "poolId aligned to pools(i)");
            assertEq(ranges[i].tickLower, TL, "tickLower as configured at initialize");
            assertEq(ranges[i].tickUpper, TU, "tickUpper as configured at initialize");
            (int24 lo, int24 hi) = mgr.rangeOf(key.toId());
            assertEq(lo, ranges[i].tickLower, "lens mirrors rangeOf");
            assertEq(hi, ranges[i].tickUpper, "lens mirrors rangeOf");
        }
    }

    function test_stableRanges_readableBeforeAnyAllocate() public view {
        // The point of the getter: with no position open there are no ticks to read off `positionOf`,
        // and nothing emits the bounds the manager would open one at.
        assertEq(mgr.openPositionCount(), 0, "nothing allocated yet");
        UniLens.StableRange[] memory ranges = lens.stableRanges(address(mgr));
        assertEq(ranges[0].tickUpper - ranges[0].tickLower, TU - TL, "bounds still readable");
    }

    // ────────── operator-swap guard status ──────────

    function test_oracleStatus_noOracle_reportsDisabledButListsCurrencies() public view {
        UniLens.OracleStatus memory st = lens.oracleStatus(address(mgr));
        assertEq(st.oracle, address(0), "no oracle wired => operator swaps fail-closed");
        assertFalse(st.isChainlinkLike, "nothing probed");
        assertEq(st.maxDeviationBps, 0);
        assertEq(st.feeds.length, mgr.managedStablesCount(), "managed currencies still enumerated");
    }

    function test_oracleStatus_chainlinkOracle_reportsConfigAndPerCurrencyFeeds() public {
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(this), 150, address(0), 0);
        MockAggregator agg = new MockAggregator(8, 1e8, block.timestamp);
        // Configure a feed for exactly one managed currency; the rest must report as unconfigured.
        Currency configured = mgr.managedStables(0);
        oracle.setFeed(configured, address(agg), 3600, 18);

        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));

        UniLens.OracleStatus memory st = lens.oracleStatus(address(mgr));
        assertEq(st.oracle, address(oracle), "wired oracle");
        assertTrue(st.isChainlinkLike, "probe succeeded");
        assertEq(st.maxDeviationBps, 150, "tolerance");
        assertEq(st.sequencerUptimeFeed, address(0), "no sequencer gate on this chain");
        assertEq(st.sequencerGracePeriod, 0);

        uint256 withFeed;
        for (uint256 i = 0; i < st.feeds.length; ++i) {
            assertEq(
                Currency.unwrap(st.feeds[i].currency),
                Currency.unwrap(mgr.managedStables(i)),
                "index-aligned to managedStables"
            );
            if (Currency.unwrap(st.feeds[i].currency) == Currency.unwrap(configured)) {
                assertEq(st.feeds[i].aggregator, address(agg), "aggregator surfaced");
                assertEq(st.feeds[i].heartbeat, 3600, "heartbeat");
                assertEq(st.feeds[i].feedDecimals, 8, "cached feed decimals");
                assertEq(st.feeds[i].tokenDecimals, 18, "token decimals");
                withFeed++;
            } else {
                // This is the diagnosis an operator bot needs BEFORE spending gas: a swap touching
                // this currency reverts OperatorSwapUnverified.
                assertEq(st.feeds[i].aggregator, address(0), "unconfigured currency is visible");
            }
        }
        assertEq(withFeed, 1, "exactly the currency we configured");
    }

    function test_oracleStatus_sequencerConfigSurfaced() public {
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(address(this), 100, address(0x5E9), 3600);
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));

        UniLens.OracleStatus memory st = lens.oracleStatus(address(mgr));
        assertEq(st.sequencerUptimeFeed, address(0x5E9), "sequencer feed");
        assertEq(st.sequencerGracePeriod, 3600, "grace period");
    }

    function test_oracleStatus_nonChainlinkOracle_degradesInsteadOfReverting() public {
        // `priceOracle` is only an IPriceOracle — a different implementation must not brick the lens.
        MockPriceOracle other = new MockPriceOracle();
        vm.prank(owner);
        mgr.setPriceOracle(address(other));

        UniLens.OracleStatus memory st = lens.oracleStatus(address(mgr));
        assertEq(st.oracle, address(other), "address still reported");
        assertFalse(st.isChainlinkLike, "probe failed => remaining fields meaningless");
        assertEq(st.maxDeviationBps, 0);
        assertEq(st.feeds.length, mgr.managedStablesCount(), "currencies still enumerated");
    }

    function test_oracleStatus_eoaOracle_degradesInsteadOfReverting() public {
        // setPriceOracle does not require a contract, so the lens must not trip the extcodesize check.
        address eoa = address(0xE0A);
        vm.prank(owner);
        mgr.setPriceOracle(eoa);

        UniLens.OracleStatus memory st = lens.oracleStatus(address(mgr));
        assertEq(st.oracle, eoa, "address reported");
        assertFalse(st.isChainlinkLike, "not probed");
    }
}
