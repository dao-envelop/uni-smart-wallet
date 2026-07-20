// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @dev Minimal Chainlink aggregator surface (subset of `AggregatorV3Interface`).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPriceOracle
/// @notice Reference {IPriceOracle} for `VolatileLPManager`: bounds an **operator-triggered** swap's
/// realized price against Chainlink USD reference feeds. For each managed currency the owner registers a
/// USD-quoted aggregator + heartbeat + token decimals; `check` computes the fair output at the reference
/// price and reverts {PriceOutOfBounds} when the realized `amountOut` is below
/// `expected * (1 - maxDeviationBps)`.
/// @dev Returns `false` (no opinion) when either side lacks a fresh reference (unconfigured, stale, a
/// non-positive answer, or a zero/future timestamp) or when the optional L2 Sequencer Uptime Feed reports
/// the sequencer down or within its restart grace period — the manager then rejects the swap for
/// operators (fail-closed) while owners bypass. `view` only. **This is a reference implementation and
/// warrants its own review before mainnet use** (feed selection, heartbeats, the sequencer feed/grace,
/// and the deviation tolerance are deployment-critical).
contract ChainlinkPriceOracle is IPriceOracle, Ownable {
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

    /// @notice USD reference feed per managed currency.
    mapping(Currency => Feed) public feeds;

    /// @notice Allowed downward deviation of realized output vs the reference-implied output, in bps.
    uint16 public maxDeviationBps;

    /// @notice Upper bound on `tokenDecimals` accepted by {setFeed}. Keeps `10 ** (feedDecimals +
    /// tokenDecimals)` in {check} well under `uint256` max (feed decimals come from the aggregator).
    uint8 internal constant MAX_TOKEN_DECIMALS = 36;

    /// @notice Optional L2 Sequencer Uptime Feed (Chainlink). Zero on L1 or on L2s Chainlink does not
    /// publish one for (e.g. Unichain) — then the sequencer gate is skipped. When set, {check} treats a
    /// down or recently-restarted sequencer as "no fresh reference" (returns false ⇒ operator swaps
    /// fail-closed), per Chainlink's L2 best practice.
    address public sequencerUptimeFeed;
    /// @notice Seconds that must elapse after the sequencer restarts before feeds are trusted again.
    uint32 public sequencerGracePeriod;

    /// @notice Emitted when a currency's feed is set or cleared.
    event FeedSet(Currency indexed currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals);
    /// @notice Emitted when the deviation tolerance changes.
    event MaxDeviationSet(uint16 bps);
    /// @notice Emitted when the sequencer uptime feed / grace period changes.
    event SequencerFeedSet(address feed, uint32 gracePeriod);

    error InvalidBps(uint16 bps);
    error PriceOutOfBounds(uint256 amountOut, uint256 minOut);
    error TokenDecimalsTooLarge(uint8 tokenDecimals);

    /// @param owner_ The protocol admin allowed to configure feeds / tolerance.
    /// @param maxDeviationBps_ Initial deviation tolerance (must be < 10_000).
    /// @param sequencerUptimeFeed_ L2 Sequencer Uptime Feed (zero ⇒ no sequencer gate; use on L1 or when
    /// none is published for the chain).
    /// @param sequencerGracePeriod_ Grace period (seconds) after a sequencer restart (Chainlink suggests 3600).
    constructor(address owner_, uint16 maxDeviationBps_, address sequencerUptimeFeed_, uint32 sequencerGracePeriod_)
        Ownable(owner_)
    {
        _setMaxDeviation(maxDeviationBps_);
        _setSequencerFeed(sequencerUptimeFeed_, sequencerGracePeriod_);
    }

    /// @notice Register (or clear, with `aggregator == address(0)`) a currency's USD feed. Owner-only.
    function setFeed(Currency currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals) external onlyOwner {
        if (aggregator != address(0) && tokenDecimals > MAX_TOKEN_DECIMALS) {
            revert TokenDecimalsTooLarge(tokenDecimals);
        }
        uint8 fd = aggregator == address(0) ? 0 : IAggregatorV3(aggregator).decimals();
        feeds[currency] =
            Feed({aggregator: aggregator, heartbeat: heartbeat, feedDecimals: fd, tokenDecimals: tokenDecimals});
        emit FeedSet(currency, aggregator, heartbeat, tokenDecimals);
    }

    /// @notice Update the deviation tolerance (bps, < 10_000). Owner-only.
    function setMaxDeviationBps(uint16 bps) external onlyOwner {
        _setMaxDeviation(bps);
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
        if (bps >= 10_000) revert InvalidBps(bps);
        maxDeviationBps = bps;
        emit MaxDeviationSet(bps);
    }

    /// @inheritdoc IPriceOracle
    function check(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (bool enforced)
    {
        // L2 sequencer gate: a down or recently-restarted sequencer ⇒ no opinion (operator fail-closed).
        if (!_sequencerUp()) return false;

        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        Currency outC = zeroForOne ? key.currency1 : key.currency0;

        (uint256 answerIn, uint8 fdIn, uint8 tdIn, bool okIn) = _read(inC);
        (uint256 answerOut, uint8 fdOut, uint8 tdOut, bool okOut) = _read(outC);
        // No fresh reference for either side, or a degenerate swap ⇒ express no opinion (fail-open here;
        // the manager fail-closes this for operators).
        if (!okIn || !okOut || amountIn == 0) return false;

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
