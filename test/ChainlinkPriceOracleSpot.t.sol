// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockAggregator, MockSequencer} from "./ChainlinkPriceOracle.t.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice A Chainlink proxy that publishes circuit-breaker bounds through an underlying aggregator, the
/// way the real `EACAggregatorProxy` + `AccessControlledOffchainAggregator` pair does.
contract MockBoundedAggregator is MockAggregator {
    address public aggregator;

    constructor(uint8 d, int256 a, uint256 t, int192 lo, int192 hi) MockAggregator(d, a, t) {
        if (lo != 0 || hi != 0) aggregator = address(new MockBounds(lo, hi));
    }

    /// @dev A Chainlink phase change: the proxy keeps its address, the aggregator behind it does not.
    function setUnderlying(address a) external {
        aggregator = a;
    }
}

contract MockBounds {
    int192 public minAnswer;
    int192 public maxAnswer;

    constructor(int192 lo, int192 hi) {
        minAnswer = lo;
        maxAnswer = hi;
    }
}

/// @notice Stands in for a manager: all the oracle asks of one is its Envelop product discriminator.
contract MockProduct {
    uint256 public immutable ORACLE_TYPE;

    constructor(uint256 t) {
        ORACLE_TYPE = t;
    }
}

/// @notice The spot half of {ChainlinkPriceOracle.check} (`amountIn == 0`), which gates operator
/// liquidity adds after audit 2026-09-04 H-1, plus the M-1 / L-3 hardening shipped with it.
///
/// The pre-existing oracle suite runs on fake currency addresses with no pool at all; the spot branch
/// reads `PoolManager.getSlot0`, so this one stands up a real pool and moves its price by initializing at
/// a chosen tick. Both currencies are quoted at $1, so the reference price is 1.0 and the pool's own tick
/// is the whole deviation.
contract ChainlinkPriceOracleSpotTest is Test {
    PoolManager internal poolManager;
    ChainlinkPriceOracle internal oracle;

    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;

    uint16 internal constant SWAP_DEV_BPS = 100; // 1%
    uint16 internal constant SPOT_DEV_BPS = 50; // 0.5%
    // 60, not 1: since the tick-spacing rule a pool finer than the tolerance is refused outright, so a
    // spacing-1 fixture would test nothing but that rule. Its own cases live in the section at the end.
    int24 internal constant SPACING = 60;

    function setUp() public {
        vm.warp(100_000);
        poolManager = new PoolManager(address(this));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(address(0))});

        oracle = new ChainlinkPriceOracle(
            address(this), IPoolManager(address(poolManager)), SWAP_DEV_BPS, SPOT_DEV_BPS, address(0), 3600
        );
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 18);
        oracle.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 18);
    }

    /// @dev Initialize the pool at `tick`. One tick is ~1 bps, so the tick doubles as the deviation.
    function _initAt(int24 tick) internal {
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
    }

    // ────────── the corridor ──────────

    function test_spot_atReference_enforced() public {
        _initAt(0);
        assertTrue(oracle.check(key, true, 0, 0), "1:1 pool matches the $1/$1 reference");
    }

    function test_spot_insideCorridor_enforced() public {
        _initAt(40); // ~ +40 bps, inside 50
        assertTrue(oracle.check(key, true, 0, 0), "inside the spot tolerance");
    }

    function test_spot_insideCorridorBelow_enforced() public {
        _initAt(-40);
        assertTrue(oracle.check(key, true, 0, 0), "inside the tolerance on the low side too");
    }

    function test_spot_aboveCorridor_reverts() public {
        _initAt(80); // ~ +80 bps, outside 50
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        oracle.check(key, true, 0, 0);
    }

    /// @dev The symmetry is the point: the swap branch only bounds the output *downward*, but a pool
    /// skewed either way lets an operator deploy principal at the wrong price.
    function test_spot_belowCorridor_reverts() public {
        _initAt(-80);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        oracle.check(key, true, 0, 0);
    }

    function test_spot_zeroForOneIrrelevant() public {
        _initAt(80);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        oracle.check(key, false, 0, 0);
    }

    /// @dev A big skew, the shape the H-1 PoC used (+6000 ticks ~ +82%).
    function test_spot_pumpedPool_reverts() public {
        _initAt(6000);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        oracle.check(key, true, 0, 0);
    }

    // ────────── no opinion (the manager fail-closes these for operators) ──────────

    function test_spot_uninitializedPool_notEnforced() public view {
        assertFalse(oracle.check(key, true, 0, 0), "no slot0 => no opinion");
    }

    function test_spot_unconfiguredCurrency_notEnforced() public {
        _initAt(0);
        oracle.setFeed(c1, address(0), 0, 0);
        assertFalse(oracle.check(key, true, 0, 0), "one side without a feed => no opinion");
    }

    function test_spot_staleFeed_notEnforced() public {
        _initAt(0);
        vm.warp(block.timestamp + 3601);
        assertFalse(oracle.check(key, true, 0, 0), "older than the heartbeat => no opinion");
    }

    function test_spot_sequencerDown_notEnforced() public {
        _initAt(6000); // skewed: without the sequencer gate this would revert
        oracle.setSequencerFeed(address(new MockSequencer(1, block.timestamp - 7200)), 3600);
        assertFalse(oracle.check(key, true, 0, 0), "sequencer down => no opinion, not a revert");
    }

    function test_spot_sequencerInGrace_notEnforced() public {
        _initAt(0);
        oracle.setSequencerFeed(address(new MockSequencer(0, block.timestamp - 60)), 3600);
        assertFalse(oracle.check(key, true, 0, 0), "restarted within the grace period => no opinion");
    }

    // ────────── decimals ──────────

    /// @dev A 6-decimal currency0 against an 18-decimal currency1: the pool's raw price is 1e-12 of the
    /// human one, and only the decimal adjustment makes it comparable to the feeds. Without it the
    /// deviation would be ~100% and every add would be refused.
    function test_spot_mismatchedDecimals_enforced() public {
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 6);
        // price(c1 per c0) = 1e12 raw => tick = log_1.0001(1e12) ≈ 276324
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(276_324));
        assertTrue(oracle.check(key, true, 0, 0), "decimal-adjusted price matches the reference");
    }

    /// @dev Feeds need not share decimals with each other either (8 vs 18 is common for L2 SVR feeds).
    function test_spot_mismatchedFeedDecimals_enforced() public {
        _initAt(0);
        oracle.setFeed(c1, address(new MockAggregator(18, int256(1e18), block.timestamp)), 3600, 18);
        assertTrue(oracle.check(key, true, 0, 0), "feed decimals normalized");
    }

    // ────────── R-2: the tick-spacing rule ──────────

    /// @dev A pool whose lattice is finer than the tolerance lets an operator park principal inside the
    /// accepted corridor and extract on every operation. Once spacing >= tolerance, nothing fits.
    function test_spacing_finerThanTolerance_reverts() public {
        PoolKey memory fine = _keyWith(1);
        poolManager.initialize(fine, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SpacingFinerThanTolerance.selector, int24(1), SPOT_DEV_BPS)
        );
        oracle.check(fine, true, 0, 0);
    }

    function test_spacing_atTolerance_allowed() public {
        PoolKey memory atEdge = _keyWith(int24(uint24(SPOT_DEV_BPS))); // spacing == tolerance
        poolManager.initialize(atEdge, TickMath.getSqrtPriceAtTick(0));
        assertTrue(oracle.check(atEdge, true, 0, 0), "spacing == tolerance leaves no room to park");
    }

    /// @dev The rule follows the tolerance, so raising the tolerance NARROWS the set of usable pools.
    function test_spacing_ruleFollowsTheTolerance() public {
        PoolKey memory k10 = _keyWith(10);
        poolManager.initialize(k10, TickMath.getSqrtPriceAtTick(0));
        oracle.setMaxSpotDeviationBps(10);
        assertTrue(oracle.check(k10, true, 0, 0), "spacing 10 is fine at a 10 bps tolerance");
        oracle.setMaxSpotDeviationBps(11);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SpacingFinerThanTolerance.selector, int24(10), uint16(11))
        );
        oracle.check(k10, true, 0, 0);
    }

    /// @dev The swap branch is unaffected: it judges a realized price, and no range is being placed.
    function test_spacing_ruleDoesNotTouchTheSwapBranch() public {
        PoolKey memory fine = _keyWith(1);
        poolManager.initialize(fine, TickMath.getSqrtPriceAtTick(0));
        assertTrue(oracle.check(fine, true, 1e18, 1e18), "a swap in a fine-spacing pool is still judged");
    }

    /// @dev StableLPManager fixes its ranges at initialization, so an operator cannot park one and the
    /// rule would only cost it pools — most stable pairs are spacing 1.
    function test_spacing_fixedRangeProductIsExempt() public {
        PoolKey memory fine = _keyWith(1);
        poolManager.initialize(fine, TickMath.getSqrtPriceAtTick(0));
        MockProduct stable = new MockProduct(3000);
        vm.prank(address(stable));
        assertTrue(oracle.check(fine, true, 0, 0), "a fixed-range product is exempt");

        MockProduct volatile_ = new MockProduct(3001);
        vm.prank(address(volatile_));
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SpacingFinerThanTolerance.selector, int24(1), SPOT_DEV_BPS)
        );
        oracle.check(fine, true, 0, 0);
    }

    /// @dev A caller that is not a manager at all gets the rule, not an exemption.
    function test_spacing_nonManagerCallerGetsTheRule() public {
        PoolKey memory fine = _keyWith(1);
        poolManager.initialize(fine, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SpacingFinerThanTolerance.selector, int24(1), SPOT_DEV_BPS)
        );
        oracle.check(fine, true, 0, 0); // this test contract has no ORACLE_TYPE
    }

    /// @dev Same pair, a different lattice — a fresh pool, since tickSpacing is part of the PoolKey.
    function _keyWith(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: spacing, hooks: IHooks(address(0))});
    }

    // ────────── R-13: refreshing a stale bounds cache ──────────

    function test_refreshBounds_rereadsAfterAPhaseChange() public {
        MockBoundedAggregator agg = new MockBoundedAggregator(8, int256(1e8), block.timestamp, 0, 0);
        oracle.setFeed(c0, address(agg), 3600, 18);
        (int128 lo0,) = oracle.feedBounds(c0);
        assertEq(lo0, int128(0), "no bounds cached at first");

        agg.setUnderlying(address(new MockBounds(int192(1e7), int192(1e12)))); // Chainlink phase change
        Currency[] memory cs = new Currency[](1);
        cs[0] = c0;
        oracle.refreshBounds(cs);

        (int128 lo, int128 hi) = oracle.feedBounds(c0);
        assertEq(lo, int128(1e7), "minAnswer picked up");
        assertEq(hi, int128(1e12), "maxAnswer picked up");
    }

    function test_refreshBounds_skipsUnconfiguredCurrencies() public {
        Currency[] memory cs = new Currency[](1);
        cs[0] = Currency.wrap(address(0xDEAD));
        oracle.refreshBounds(cs); // must not revert
    }

    // ────────── M-1: the owner's room to disable the guard ──────────

    function test_deviationCapsAreEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.InvalidBps.selector, uint16(1_001)));
        oracle.setMaxSpotDeviationBps(1_001);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceOracle.InvalidBps.selector, uint16(9_999)));
        oracle.setMaxDeviationBps(9_999);
        oracle.setMaxSpotDeviationBps(1_000); // the cap itself is allowed
        assertEq(oracle.maxSpotDeviationBps(), 1_000);
    }

    function test_ownershipTransferIsTwoStep() public {
        address next = address(0xBEEF);
        oracle.transferOwnership(next);
        assertEq(oracle.owner(), address(this), "ownership does not move on the first step");
        vm.prank(next);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), next, "moved once accepted");
    }

    // ────────── L-3: circuit-breaker bounds ──────────

    function test_answerAtMinAnswer_notEnforced() public {
        _initAt(0);
        // A feed whose answer sits on its floor is reporting the floor, not the market (Venus/Blizz on
        // LUNA). $0.10 with a floor of $0.10.
        oracle.setFeed(
            c0, address(new MockBoundedAggregator(8, int256(1e7), block.timestamp, int192(1e7), int192(1e12))), 3600, 18
        );
        assertFalse(oracle.check(key, true, 0, 0), "answer pinned at minAnswer => no reference");
    }

    function test_answerAboveMinAnswer_stillRead() public {
        _initAt(0);
        oracle.setFeed(
            c0, address(new MockBoundedAggregator(8, int256(1e8), block.timestamp, int192(1e7), int192(1e12))), 3600, 18
        );
        assertTrue(oracle.check(key, true, 0, 0), "inside its bounds => an ordinary reference");
        (int128 lo, int128 hi) = oracle.feedBounds(c0);
        assertEq(lo, int128(1e7), "minAnswer cached");
        assertEq(hi, int128(1e12), "maxAnswer cached");
    }

    function test_aggregatorWithoutBounds_cachesNone() public {
        _initAt(0);
        (int128 lo, int128 hi) = oracle.feedBounds(c0); // plain MockAggregator from setUp
        assertEq(lo, int128(0), "no minAnswer published");
        assertEq(hi, int128(0), "no maxAnswer published");
        assertTrue(oracle.check(key, true, 0, 0), "and the feed is used normally");
    }

    function test_clearingAFeedClearsItsBounds() public {
        oracle.setFeed(
            c0, address(new MockBoundedAggregator(8, int256(1e8), block.timestamp, int192(1e7), int192(1e12))), 3600, 18
        );
        oracle.setFeed(c0, address(0), 0, 0);
        (int128 lo, int128 hi) = oracle.feedBounds(c0);
        assertEq(lo, int128(0));
        assertEq(hi, int128(0));
    }
}
