// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Minimal Chainlink surface: the historical reads this test needs on top of `latestRoundData`.
interface IAggV3Rounds {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Arbitrum-fork audit of the staleness bounds shipped in `script/oracle_feeds.json` (task_045).
///
/// Chainlink's published heartbeat is the interval at which a new round is *triggered*; the resulting
/// `updatedAt` lands ~15s later, after round negotiation, transmission and inclusion. So a staleness bound
/// equal to the published heartbeat is unreachable by construction — the feed cannot be fresher than it
/// publishes — and `ChainlinkPriceOracle._read` reports "no reference", closing the fail-closed operator
/// swap gate. On Arbitrum USDC/USDT that is a 255s bound against a ~270s cadence: ≈5.6 % of operator swaps
/// reverting for no interpretable reason.
///
/// This measures the real cadence against the LIVE aggregators and asserts the shipped padded bound clears
/// it with margin, while the published value does not. It reads the bounds out of `oracle_feeds.json`
/// rather than hard-coding them, so it audits the shipped config rather than a copy of it.
///
/// Env-gated like the other fork suites — CI has no RPC secrets, so it skips there. The CI-enforced
/// regression guards are `test/SetOracleFeeds.t.sol` (lints the pad on every row) and
/// `test/ChainlinkPriceOracle.t.sol` (pins the freshness mechanism); this suite is the manual audit that
/// checks the numbers against reality.
///
///   ARBITRUM_RPC=https://arb1.arbitrum.io/rpc forge test --match-path test/OracleHeartbeat.fork.t.sol -vvv
contract OracleHeartbeatForkTest is Test {
    bool internal forkActive;

    /// @dev Rounds walked back from `latestRoundData` per feed.
    uint256 internal constant ROUNDS = 20;

    string internal feedsJson;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "ARBITRUM_RPC unset; skipping Arbitrum oracle heartbeat audit");
            return;
        }
        uint256 forkBlock = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forkActive = true;

        feedsJson = vm.readFile("script/oracle_feeds.json");
    }

    /// @notice The stablecoin feeds that actually fired the defect: both sides of the stable pairs the
    /// `arb-vol` manager holds, where USDC is `currency1` in every open position.
    function test_arbitrumStables_paddedHeartbeatClearsRealCadence() public view {
        if (!forkActive) return;
        _assertPaddedBoundClearsCadence("USDC");
        _assertPaddedBoundClearsCadence("USDT");
    }

    /// @notice The 1755s feeds — the same defect, not yet fired. They are deviation-driven, so on a quiet
    /// market they may go quiet up to their real heartbeat; the finding measured an ETH interval of 1680s
    /// against a 1755s bound, 4 % of margin. Padded, the margin no longer depends on market activity.
    function test_arbitrumMajors_paddedHeartbeatClearsRealCadence() public view {
        if (!forkActive) return;
        _assertPaddedBoundClearsCadence("ETH");
        _assertPaddedBoundClearsCadence("BTC");
        _assertPaddedBoundClearsCadence("LINK");
    }

    /// @dev Walk `ROUNDS` rounds back from the head and compare the widest observed publication interval
    /// against both bounds in the shipped config.
    function _assertPaddedBoundClearsCadence(string memory symbol) internal view {
        string memory base = string.concat('.["42161"].', symbol);
        address aggregator = vm.parseJsonAddress(feedsJson, string.concat(base, ".aggregator"));
        uint256 published = vm.parseJsonUint(feedsJson, string.concat(base, ".publishedHeartbeat"));
        uint256 padded = vm.parseJsonUint(feedsJson, string.concat(base, ".heartbeat"));

        (uint256 maxInterval, uint256 sampled) = _maxInterval(aggregator);
        assertGt(sampled, 2, string.concat("too few rounds sampled for ", symbol));

        console2.log(symbol);
        console2.log("  intervals sampled:", sampled);
        console2.log("  max interval (s): ", maxInterval);
        console2.log("  published / padded:", published, padded);

        assertGt(padded, maxInterval, string.concat("padded bound must clear the observed cadence: ", symbol));
        // The pad must be real margin, not a rounding accident.
        assertGt(padded - maxInterval, published / 2, string.concat("padded bound margin too thin: ", symbol));

        // Documents *why* the pad exists: on the stables the published value is at or under the cadence,
        // so a bound set to it would reject a feed as fresh as it can ever be. Not asserted for the
        // deviation-driven majors, which usually publish well inside their heartbeat.
        if (published < 1000) {
            assertLe(published, maxInterval, string.concat("published bound is under the cadence: ", symbol));
        }
    }

    /// @dev Max gap between consecutive `updatedAt` values, walking back from the latest round. Proxy
    /// round IDs are `(phaseId << 64) | aggregatorRoundId`, so decrementing crosses a phase boundary into
    /// unset rounds — stop there rather than reading zeros as data.
    function _maxInterval(address aggregator) internal view returns (uint256 maxInterval, uint256 sampled) {
        IAggV3Rounds feed = IAggV3Rounds(aggregator);
        (uint80 roundId,,, uint256 next,) = feed.latestRoundData();
        require(next != 0, "no latest round");

        for (uint256 i = 1; i <= ROUNDS; ++i) {
            if (roundId < uint80(i)) break;
            (,,, uint256 updatedAt,) = feed.getRoundData(roundId - uint80(i));
            if (updatedAt == 0 || updatedAt >= next) break; // phase boundary or non-monotonic
            uint256 interval = next - updatedAt;
            if (interval > maxInterval) maxInterval = interval;
            next = updatedAt;
            ++sampled;
        }
    }
}
