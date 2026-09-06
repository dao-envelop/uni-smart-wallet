// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @dev Minimal Chainlink aggregator surface (subset of `AggregatorV3Interface`).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Circuit-breaker surface. `minAnswer`/`maxAnswer` live on the *underlying* aggregator, not on the
/// proxy that is normally registered as the feed — hence `aggregator()` to hop from one to the other.
/// Every call site probes these with `try`: most modern feeds expose none of them.
interface IAggregatorBounds {
    function aggregator() external view returns (address);
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @title ChainlinkPriceOracle
/// @notice Reference {IPriceOracle} for the LP managers: bounds **operator-triggered** value moves
/// against Chainlink USD reference feeds. For each managed currency the owner registers a USD-quoted
/// aggregator + heartbeat + token decimals, and `check` answers two different questions:
/// - **swap** (`amountIn > 0`): the fair output at the reference price, reverting {PriceOutOfBounds}
///   when the realized `amountOut` is below `expected * (1 - maxDeviationBps)`;
/// - **spot** (`amountIn == 0`): the pool's own `slot0` price against the reference, reverting
///   {SpotPriceOutOfBounds} when it is off by more than `maxSpotDeviationBps` **in either direction**.
/// The spot branch is what gates operator liquidity *adds* (audit 2026-09-04, H-1): sizing L from
/// `getSlot0` bounds the quantity deployed but not the price it is deployed at, so an operator could
/// skew a thin pool, deploy principal into a narrow range at the skewed price and trade back through it.
/// The two tolerances are separate on purpose: the swap one folds in the pool fee (it compares a realized
/// output), a spot comparison does not, so it is set tighter.
/// @dev Returns `false` (no opinion) when either side lacks a fresh reference (unconfigured, stale, a
/// non-positive answer, an answer pinned at the aggregator's `minAnswer`/`maxAnswer`, or a zero/future
/// timestamp), when the pool is uninitialized, or when the optional L2 Sequencer Uptime Feed reports the
/// sequencer down or within its restart grace period — the manager then rejects the operation for
/// operators (fail-closed) while owners bypass. `view` only. **This is a reference implementation and
/// warrants its own review before mainnet use** (feed selection, heartbeats, the sequencer feed/grace,
/// and both deviation tolerances are deployment-critical).
contract ChainlinkPriceOracle is IPriceOracle, Ownable2Step {
    using StateLibrary for IPoolManager;

    /// @param aggregator The Chainlink USD feed for the currency (zero ⇒ unconfigured).
    /// @param heartbeat Max age (seconds) of a fresh answer; older ⇒ treated as no reference.
    /// @param feedDecimals Cached `aggregator.decimals()`.
    /// @param tokenDecimals The currency's ERC-20 decimals (18 for native).
    struct Feed {
        address aggregator;
        uint32 heartbeat;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    /// @param minAnswer The aggregator's lower circuit-breaker, or 0 when it publishes none.
    /// @param maxAnswer The aggregator's upper circuit-breaker, or 0 when it publishes none.
    /// @dev Cached at {setFeed} time and packed into one slot. Bounds outside `int128` are recorded as
    /// "none": a feed whose `maxAnswer` is the `int192` sentinel has its circuit-breaker disabled anyway,
    /// which is the modern default.
    struct Bounds {
        int128 minAnswer;
        int128 maxAnswer;
    }

    /// @notice USD reference feed per managed currency.
    mapping(Currency => Feed) public feeds;

    /// @notice Cached circuit-breaker bounds per managed currency (see {Bounds}).
    /// @dev Separate from {feeds} because that struct already fills its slot, and because the lens and
    /// `SetOracleFeeds` read `feeds` as a fixed 4-tuple.
    mapping(Currency => Bounds) public feedBounds;

    /// @notice Allowed downward deviation of realized output vs the reference-implied output, in bps.
    uint16 public maxDeviationBps;

    /// @notice Allowed deviation, in bps and in **either** direction, of a pool's `slot0` price vs the
    /// reference-implied price. Gates operator liquidity adds.
    uint16 public maxSpotDeviationBps;

    /// @notice The v4 `PoolManager` whose `slot0` the spot branch reads.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Upper bound on `tokenDecimals` accepted by {setFeed}. Keeps `10 ** (feedDecimals +
    /// tokenDecimals)` in {check} well under `uint256` max (feed decimals come from the aggregator).
    uint8 internal constant MAX_TOKEN_DECIMALS = 36;

    /// @notice Hard ceiling on both tolerances. Without it the oracle owner could raise a tolerance to
    /// 99.99% and leave the guard nominally wired but economically absent (audit 2026-09-04, M-1).
    uint16 internal constant MAX_DEVIATION_CAP = 1_000; // 10%

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = FixedPoint96.Q96; // 2**96

    /// @notice Optional L2 Sequencer Uptime Feed (Chainlink). Zero on L1 or on L2s Chainlink does not
    /// publish one for (e.g. Unichain) — then the sequencer gate is skipped. When set, {check} treats a
    /// down or recently-restarted sequencer as "no fresh reference" (returns false ⇒ operator swaps
    /// fail-closed), per Chainlink's L2 best practice.
    address public sequencerUptimeFeed;
    /// @notice Seconds that must elapse after the sequencer restarts before feeds are trusted again.
    uint32 public sequencerGracePeriod;

    /// @notice Emitted when a currency's feed is set or cleared.
    event FeedSet(Currency indexed currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals);
    /// @notice Emitted when a currency's cached circuit-breaker bounds are set or cleared.
    event FeedBoundsSet(Currency indexed currency, int128 minAnswer, int128 maxAnswer);
    /// @notice Emitted when the swap deviation tolerance changes.
    event MaxDeviationSet(uint16 bps);
    /// @notice Emitted when the spot deviation tolerance changes.
    event MaxSpotDeviationSet(uint16 bps);
    /// @notice Emitted when the sequencer uptime feed / grace period changes.
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    error InvalidBps(uint16 bps);
    error PriceOutOfBounds(uint256 amountOut, uint256 minOut);
    error SpotPriceOutOfBounds(uint256 poolPrice, uint256 referencePrice);
    error TokenDecimalsTooLarge(uint8 tokenDecimals);

    /// @param owner_ The protocol admin allowed to configure feeds / tolerances.
    /// @param poolManager_ The v4 `PoolManager` the spot branch reads `slot0` from.
    /// @param maxDeviationBps_ Initial swap tolerance (must be ≤ {MAX_DEVIATION_CAP}).
    /// @param maxSpotDeviationBps_ Initial spot tolerance (must be ≤ {MAX_DEVIATION_CAP}); set it tighter
    /// than the swap one — it compares prices, not fee-bearing outputs.
    /// @param sequencerUptimeFeed_ L2 Sequencer Uptime Feed (zero ⇒ no sequencer gate; use on L1 or when
    /// none is published for the chain).
    /// @param sequencerGracePeriod_ Grace period (seconds) after a sequencer restart (Chainlink suggests 3600).
    constructor(
        address owner_,
        IPoolManager poolManager_,
        uint16 maxDeviationBps_,
        uint16 maxSpotDeviationBps_,
        address sequencerUptimeFeed_,
        uint32 sequencerGracePeriod_
    ) Ownable(owner_) {
        POOL_MANAGER = poolManager_;
        _setMaxDeviation(maxDeviationBps_);
        _setMaxSpotDeviation(maxSpotDeviationBps_);
        _setSequencerFeed(sequencerUptimeFeed_, sequencerGracePeriod_);
    }

    /// @notice Register (or clear, with `aggregator == address(0)`) a currency's USD feed. Owner-only.
    /// @dev Also caches the aggregator's circuit-breaker bounds. Chainlink can swap the aggregator behind
    /// a proxy (a phase change), which leaves the cache stale — re-run `SetOracleFeeds` after one.
    function setFeed(Currency currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals) external onlyOwner {
        if (aggregator != address(0) && tokenDecimals > MAX_TOKEN_DECIMALS) {
            revert TokenDecimalsTooLarge(tokenDecimals);
        }
        uint8 fd = aggregator == address(0) ? 0 : IAggregatorV3(aggregator).decimals();
        feeds[currency] =
            Feed({aggregator: aggregator, heartbeat: heartbeat, feedDecimals: fd, tokenDecimals: tokenDecimals});
        emit FeedSet(currency, aggregator, heartbeat, tokenDecimals);

        Bounds memory b = aggregator == address(0) ? Bounds(0, 0) : _readBounds(aggregator);
        feedBounds[currency] = b;
        emit FeedBoundsSet(currency, b.minAnswer, b.maxAnswer);
    }

    /// @notice Update the swap deviation tolerance (bps, ≤ {MAX_DEVIATION_CAP}). Owner-only.
    function setMaxDeviationBps(uint16 bps) external onlyOwner {
        _setMaxDeviation(bps);
    }

    /// @notice Update the spot deviation tolerance (bps, ≤ {MAX_DEVIATION_CAP}). Owner-only.
    function setMaxSpotDeviationBps(uint16 bps) external onlyOwner {
        _setMaxSpotDeviation(bps);
    }

    /// @notice Set (or clear, with `feed == address(0)`) the L2 Sequencer Uptime Feed + grace period. Owner-only.
    function setSequencerFeed(address feed, uint32 gracePeriod) external onlyOwner {
        _setSequencerFeed(feed, gracePeriod);
    }

    function _setSequencerFeed(address feed, uint32 gracePeriod) internal {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    function _setMaxDeviation(uint16 bps) internal {
        if (bps > MAX_DEVIATION_CAP) revert InvalidBps(bps);
        maxDeviationBps = bps;
        emit MaxDeviationSet(bps);
    }

    function _setMaxSpotDeviation(uint16 bps) internal {
        if (bps > MAX_DEVIATION_CAP) revert InvalidBps(bps);
        maxSpotDeviationBps = bps;
        emit MaxSpotDeviationSet(bps);
    }

    /// @dev Best-effort read of an aggregator's circuit-breaker bounds. They live on the underlying
    /// aggregator rather than the registered proxy, and most feeds expose neither — every step is `try`,
    /// and anything missing or wider than `int128` is recorded as "no bound".
    function _readBounds(address aggregator) internal view returns (Bounds memory b) {
        address impl = aggregator;
        try IAggregatorBounds(aggregator).aggregator() returns (address a) {
            if (a != address(0)) impl = a;
        } catch {}
        try IAggregatorBounds(impl).minAnswer() returns (int192 lo) {
            if (lo >= type(int128).min && lo <= type(int128).max) b.minAnswer = int128(lo);
        } catch {}
        try IAggregatorBounds(impl).maxAnswer() returns (int192 hi) {
            if (hi >= type(int128).min && hi <= type(int128).max) b.maxAnswer = int128(hi);
        } catch {}
    }

    /// @inheritdoc IPriceOracle
    function check(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (bool enforced)
    {
        // L2 sequencer gate: a down or recently-restarted sequencer ⇒ no opinion (operator fail-closed).
        if (!_sequencerUp()) return false;

        // `amountIn == 0` is the spot sentinel: no swap happened, so there is no realized price to
        // judge — check the pool's own price instead. Nothing else reaches this with a zero input: the
        // swap paths call the guard only for `swapAmountIn > 0`, and their full-fill check already
        // rejects an under-filled swap. `zeroForOne` plays no part there — a skewed pool is skewed for
        // both directions of a subsequent add.
        if (amountIn == 0) return _checkSpot(key);

        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;

        (uint256 answerIn, uint8 fdIn, uint8 tdIn, bool okIn) = _read(inC);
        (uint256 answerOut, uint8 fdOut, uint8 tdOut, bool okOut) = _read(outC);
        // No fresh reference for either side ⇒ express no opinion (fail-open here; the manager
        // fail-closes this for operators).
        if (!okIn || !okOut) return false;

        // Fair output at the reference price (both feeds USD-quoted):
        //   expectedOut = amountIn * answerIn * 10^(fdOut+tdOut) / (answerOut * 10^(fdIn+tdIn))
        // Split across two mulDiv steps so no intermediate overflows uint256.
        uint256 step1 = FullMath.mulDiv(amountIn, answerIn, answerOut);
        uint256 expectedOut =
            FullMath.mulDiv(step1, 10 ** (uint256(fdOut) + uint256(tdOut)), 10 ** (uint256(fdIn) + uint256(tdIn)));

        uint256 minOut = FullMath.mulDiv(expectedOut, 10_000 - maxDeviationBps, 10_000);
        if (amountOut < minOut) revert PriceOutOfBounds(amountOut, minOut);
        return true;
    }

    /// @dev The spot half of {check}: the pool's `slot0` price vs the reference-implied one, both as
    /// currency1-per-currency0 scaled by 1e18, compared **symmetrically**. Reads its own references
    /// instead of taking the swap path's in/out pair — that keeps the sides named after the pool's own
    /// ordering, and the swap path's reads are skipped for a spot check anyway.
    /// @return enforced True when the pool price is within `maxSpotDeviationBps` of the reference; false
    /// when either side lacks a fresh reference, the pool is uninitialized, or a price degenerates to
    /// zero (no opinion — the manager fail-closes that for operators).
    function _checkSpot(PoolKey calldata key) internal view returns (bool enforced) {
        (uint256 a0, uint8 fd0, uint8 td0, bool ok0) = _read(key.currency0);
        (uint256 a1, uint8 fd1, uint8 td1, bool ok1) = _read(key.currency1);
        if (!ok0 || !ok1) return false;

        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sqrtP == 0) return false; // uninitialized pool ⇒ no opinion (operator fail-closed upstream)

        // Pool price, currency1 per currency0, decimal-adjusted, 1e18-scaled. Split across two mulDiv
        // steps: `sqrtP * sqrtP / 2**192` in one expression overflows.
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), Q96);
        uint256 poolPrice = FullMath.mulDiv(priceX96, WAD * (10 ** td0), Q96 * (10 ** td1));
        // Reference price implied by the two USD feeds: usd0/usd1, same units.
        uint256 refPrice = FullMath.mulDiv(a0, (10 ** fd1) * WAD, a1 * (10 ** fd0));
        if (poolPrice == 0 || refPrice == 0) return false;

        uint256 diff = poolPrice > refPrice ? poolPrice - refPrice : refPrice - poolPrice;
        if (FullMath.mulDiv(diff, 10_000, refPrice) > maxSpotDeviationBps) {
            revert SpotPriceOutOfBounds(poolPrice, refPrice);
        }
        return true;
    }

    /// @dev Read a currency's reference: (answer, feedDecimals, tokenDecimals, fresh?).
    function _read(Currency c)
        internal
        view
        returns (uint256 answer, uint8 feedDecimals, uint8 tokenDecimals, bool ok)
    {
        Feed memory f = feeds[c];
        if (f.aggregator == address(0)) return (0, 0, 0, false);
        (, int256 a,, uint256 updatedAt,) = IAggregatorV3(f.aggregator).latestRoundData();
        // No opinion on a non-positive answer, a zero/future timestamp (guards the underflow below), or a
        // reference older than the heartbeat.
        if (a <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > f.heartbeat) {
            return (0, 0, 0, false);
        }
        // An answer pinned at the aggregator's circuit breaker is the floor/ceiling, not the market: in a
        // flash crash below `minAnswer` the feed keeps reporting the floor (Venus/Blizz on LUNA). Treat it
        // as no reference rather than vouch for an operation against a price that is known to be wrong.
        Bounds memory b = feedBounds[c];
        if ((b.minAnswer != 0 && a <= b.minAnswer) || (b.maxAnswer != 0 && a >= b.maxAnswer)) {
            return (0, 0, 0, false);
        }
        return (uint256(a), f.feedDecimals, f.tokenDecimals, true);
    }

    /// @dev L2 sequencer liveness (Chainlink): up feed answer 0 = up, 1 = down; require up AND past the
    /// grace period since the round started. No feed configured ⇒ treated as up (L1 / unsupported chain).
    function _sequencerUp() internal view returns (bool) {
        address seq = sequencerUptimeFeed;
        if (seq == address(0)) return true;
        (, int256 answer, uint256 startedAt,,) = IAggregatorV3(seq).latestRoundData();
        if (answer != 0) return false; // 1 = sequencer down
        if (startedAt == 0 || startedAt > block.timestamp) return false; // invalid / future round
        return block.timestamp - startedAt > sequencerGracePeriod; // still within grace ⇒ not trusted yet
    }
}
