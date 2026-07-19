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
/// @dev Returns `false` (no opinion) when either side lacks a fresh reference (unconfigured, stale, or a
/// non-positive answer) — the manager then rejects the swap for operators (fail-closed) while owners
/// bypass. `view` only. **This is a reference implementation and warrants its own review before mainnet
/// use** (feed selection, heartbeats, and the deviation tolerance are deployment-critical).
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

    /// @notice Emitted when a currency's feed is set or cleared.
    event FeedSet(Currency indexed currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals);
    /// @notice Emitted when the deviation tolerance changes.
    event MaxDeviationSet(uint16 bps);

    error InvalidBps(uint16 bps);
    error PriceOutOfBounds(uint256 amountOut, uint256 minOut);

    /// @param owner_ The protocol admin allowed to configure feeds / tolerance.
    /// @param maxDeviationBps_ Initial deviation tolerance (must be < 10_000).
    constructor(address owner_, uint16 maxDeviationBps_) Ownable(owner_) {
        _setMaxDeviation(maxDeviationBps_);
    }

    /// @notice Register (or clear, with `aggregator == address(0)`) a currency's USD feed. Owner-only.
    function setFeed(Currency currency, address aggregator, uint32 heartbeat, uint8 tokenDecimals) external onlyOwner {
        uint8 fd = aggregator == address(0) ? 0 : IAggregatorV3(aggregator).decimals();
        feeds[currency] =
            Feed({aggregator: aggregator, heartbeat: heartbeat, feedDecimals: fd, tokenDecimals: tokenDecimals});
        emit FeedSet(currency, aggregator, heartbeat, tokenDecimals);
    }

    /// @notice Update the deviation tolerance (bps, < 10_000). Owner-only.
    function setMaxDeviationBps(uint16 bps) external onlyOwner {
        _setMaxDeviation(bps);
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
        if (a <= 0 || block.timestamp - updatedAt > f.heartbeat) return (0, 0, 0, false);
        return (uint256(a), f.feedDecimals, f.tokenDecimals, true);
    }
}
