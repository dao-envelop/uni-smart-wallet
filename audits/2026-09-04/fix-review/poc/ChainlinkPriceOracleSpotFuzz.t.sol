// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Differential audit of the arithmetic in `ChainlinkPriceOracle._checkSpot` (audit 2026-09-04,
/// H-1 fix). The expected verdict is derived from an *exact rational* model of the two definitions
/// (`test/ffi/spot_exact.py`, arbitrary-precision Python), never from a second copy of the on-chain
/// expression — an error the Solidity formula makes is therefore visible as a disagreement rather than
/// reproduced identically.
contract ChainlinkPriceOracleSpotFuzzTest is Test {
    PoolManager internal pm;
    ChainlinkPriceOracle internal oracle;

    Currency internal c0;
    Currency internal c1;

    uint16 internal constant SWAP_DEV_BPS = 100;
    uint16 internal constant SPOT_DEV_BPS = 50; // 0.5%
    uint16 internal constant CAP_BPS = 1_000; // MAX_DEVIATION_CAP

    uint24 internal feeCounter;

    // Current oracle configuration, mirrored so the FFI reference is fed the same inputs.
    uint8 internal td0;
    uint8 internal td1;
    uint8 internal fd0;
    uint8 internal fd1;
    uint256 internal ans0;
    uint256 internal ans1;

    enum Outcome {
        Enforced, // returned true
        NoOpinion, // returned false
        SpotRevert, // SpotPriceOutOfBounds
        Panic, // Panic(uint256) — arithmetic over/underflow etc.
        BareRevert, // revert with empty returndata (FullMath.mulDiv's `require(denominator > prod1)`)
        OtherRevert
    }

    function setUp() public {
        vm.warp(100_000);
        pm = new PoolManager(address(this));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        oracle = new ChainlinkPriceOracle(
            address(this), IPoolManager(address(pm)), SWAP_DEV_BPS, SPOT_DEV_BPS, address(0), 3600
        );
        _configure(18, 18, 8, 8, 1e8, 1e8);
    }

    // ─────────────────────────── harness ───────────────────────────

    function _configure(uint8 t0, uint8 t1, uint8 f0, uint8 f1, uint256 a0, uint256 a1) internal {
        td0 = t0;
        td1 = t1;
        fd0 = f0;
        fd1 = f1;
        ans0 = a0;
        ans1 = a1;
        oracle.setFeed(c0, address(new MockAggregator(f0, int256(a0), block.timestamp)), 3600, t0);
        oracle.setFeed(c1, address(new MockAggregator(f1, int256(a1), block.timestamp)), 3600, t1);
    }

    /// @dev A fresh pool (distinct `fee` ⇒ distinct PoolId) initialised at `sqrtP`.
    function _poolAt(uint160 sqrtP) internal returns (PoolKey memory key) {
        feeCounter++;
        key = PoolKey({currency0: c0, currency1: c1, fee: feeCounter, tickSpacing: 1, hooks: IHooks(address(0))});
        pm.initialize(key, sqrtP);
    }

    function _poolAtTick(int24 tick) internal returns (PoolKey memory key) {
        return _poolAt(TickMath.getSqrtPriceAtTick(tick));
    }

    function _check(PoolKey memory key) internal view returns (Outcome o, bytes memory data) {
        (bool ok, bytes memory ret) =
            address(oracle).staticcall(abi.encodeWithSelector(ChainlinkPriceOracle.check.selector, key, true, 0, 0));
        data = ret;
        if (ok) return (abi.decode(ret, (bool)) ? Outcome.Enforced : Outcome.NoOpinion, ret);
        if (ret.length == 0) return (Outcome.BareRevert, ret);
        bytes4 sel = bytes4(ret);
        if (sel == ChainlinkPriceOracle.SpotPriceOutOfBounds.selector) return (Outcome.SpotRevert, ret);
        if (sel == bytes4(keccak256("Panic(uint256)"))) return (Outcome.Panic, ret);
        return (Outcome.OtherRevert, ret);
    }

    /// @dev The sqrtPriceX96 at which the pool exactly matches the reference, from the exact model.
    function _idealSqrt() internal returns (uint160) {
        string[] memory cmd = new string[](9);
        cmd[0] = "python3";
        cmd[1] = "test/ffi/spot_exact.py";
        cmd[2] = "ideal";
        cmd[3] = vm.toString(uint256(td0));
        cmd[4] = vm.toString(uint256(td1));
        cmd[5] = vm.toString(uint256(fd0));
        cmd[6] = vm.toString(uint256(fd1));
        cmd[7] = vm.toString(ans0);
        cmd[8] = vm.toString(ans1);
        return uint160(abi.decode(vm.ffi(cmd), (uint256)));
    }

    /// @dev Exact |pool-ref|/ref in bps, scaled by 1e18, for one sqrtP.
    function _exactDevBpsX18(uint160 sqrtP) internal returns (uint256) {
        string[] memory cmd = new string[](10);
        cmd[0] = "python3";
        cmd[1] = "test/ffi/spot_exact.py";
        cmd[2] = "dev";
        cmd[3] = vm.toString(uint256(td0));
        cmd[4] = vm.toString(uint256(td1));
        cmd[5] = vm.toString(uint256(fd0));
        cmd[6] = vm.toString(uint256(fd1));
        cmd[7] = vm.toString(ans0);
        cmd[8] = vm.toString(ans1);
        cmd[9] = vm.toString(uint256(sqrtP));
        return abi.decode(vm.ffi(cmd), (uint256));
    }

    // ─────────────────────────── 1. differential sweep ───────────────────────────

    uint8[6] internal TD = [0, 6, 8, 18, 27, 36];
    uint8[3] internal FD = [6, 8, 18];

    /// @notice The core differential: for every decimals combination, walk the pool price across the
    /// tolerance boundary and require the contract's verdict to agree with the exact model.
    /// @dev Records the worst disagreement rather than failing on the first one, so the report can state
    /// the magnitude. The assertion at the end is what bites.
    // Accumulators kept in storage: the sweep is too deep for the stack otherwise.
    uint256 internal worstFailOpenX18;
    uint256 internal worstFailClosedX18;
    uint256 internal worstFailOpenTd0;
    uint256 internal worstFailOpenTd1;
    uint256 internal worstFailClosedTd0;
    uint256 internal worstFailClosedTd1;
    uint256 internal worstFailClosedExactX18;
    uint256 internal nBare;
    uint256 internal nPanic;

    function test_differentialSweep_decimalsMatrix() public {
        for (uint256 i = 0; i < TD.length; i++) {
            for (uint256 j = 0; j < TD.length; j++) {
                _sweepOneConfig(TD[i], TD[j]);
            }
        }

        console2.log("worst FAIL-OPEN, exact deviation accepted (bps x1e18):", worstFailOpenX18);
        console2.log("  at td0:", worstFailOpenTd0);
        console2.log("  at td1:", worstFailOpenTd1);
        console2.log(
            "worst FAIL-CLOSED: rejected a pool whose exact deviation was (bps x1e18):", worstFailClosedExactX18
        );
        console2.log("  at td0:", worstFailClosedTd0);
        console2.log("  at td1:", worstFailClosedTd1);
        console2.log("bare reverts (FullMath overflow):", nBare);
        console2.log("panics:", nPanic);

        // The gate is only sound if the accepted set never reaches materially past the tolerance.
        // 1e18 == 1 bps of slack for the final floor().
        assertLe(worstFailOpenX18, uint256(SPOT_DEV_BPS) * 1e18 + 1e18, "spot gate accepted a price outside tolerance");
        assertLe(worstFailClosedX18, 1e18, "spot gate rejected a price inside tolerance");
    }

    function _sweepOneConfig(uint8 t0, uint8 t1) internal {
        _configure(t0, t1, 8, 8, 1e8, 1e8);
        uint160 ideal = _idealSqrt();
        if (ideal < TickMath.MIN_SQRT_PRICE || ideal >= TickMath.MAX_SQRT_PRICE) return;
        int24 center = TickMath.getTickAtSqrtPrice(ideal);
        int24[11] memory offs = [int24(0), 1, -1, 25, -25, 49, -49, 50, -50, 60, -60];
        for (uint256 k = 0; k < offs.length; k++) {
            int24 t = center + offs[k];
            if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) continue;
            _probe(TickMath.getSqrtPriceAtTick(t), t0, t1);
        }
    }

    function _probe(uint160 sp, uint8 t0, uint8 t1) internal {
        PoolKey memory key = _poolAt(sp);
        (Outcome o,) = _check(key);
        if (o == Outcome.BareRevert) {
            nBare++;
            return;
        }
        if (o == Outcome.Panic) {
            nPanic++;
            return;
        }
        if (o == Outcome.NoOpinion) return; // degenerate (price rounds to 0)
        uint256 exact = _exactDevBpsX18(sp);
        bool shouldPass = exact <= uint256(SPOT_DEV_BPS) * 1e18;
        if (o == Outcome.Enforced && !shouldPass && exact > worstFailOpenX18) {
            worstFailOpenX18 = exact;
            worstFailOpenTd0 = t0;
            worstFailOpenTd1 = t1;
        }
        if (o == Outcome.SpotRevert && shouldPass) {
            uint256 margin = uint256(SPOT_DEV_BPS) * 1e18 - exact;
            if (margin > worstFailClosedX18) {
                worstFailClosedX18 = margin;
                worstFailClosedTd0 = t0;
                worstFailClosedTd1 = t1;
                worstFailClosedExactX18 = exact;
            }
        }
    }

    /// @notice Negative control: the same sweep with the exact model fed *swapped* token decimals must
    /// fail. If it passed, the assertions above would be vacuous.
    function test_differentialSweep_negativeControl() public {
        (bool ok,) = address(this).call(abi.encodeWithSelector(this.sweepWithBrokenReference.selector));
        assertFalse(ok, "a deliberately wrong reference must break the differential assertions");
    }

    function sweepWithBrokenReference() external {
        _configure(18, 6, 8, 8, 1e8, 1e8);
        uint160 ideal = _idealSqrt();
        // Corrupt the model's view of the configuration, exactly as a wrong decimal adjustment would.
        (td0, td1) = (td1, td0);
        uint256 exact = _exactDevBpsX18(ideal);
        (td0, td1) = (td1, td0);
        PoolKey memory key = _poolAt(ideal);
        (Outcome o,) = _check(key);
        bool shouldPass = exact <= uint256(SPOT_DEV_BPS) * 1e18;
        assertEq(o == Outcome.Enforced, shouldPass, "control");
    }

    // ─────────────────────────── 2. fuzz ───────────────────────────

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_spotVerdictMatchesExactModel(uint8 i, uint8 j, uint8 f, int24 off, uint64 mul) public {
        _configure(TD[i % 6], TD[j % 6], FD[f % 3], FD[(f / 3) % 3], 1e8, 1e8);
        // Feed answers spanning tiny to enormous, still positive.
        uint256 a0 = uint256(mul) + 1;
        uint256 a1 = 1e8;
        _configure(td0, td1, fd0, fd1, a0, a1);

        uint160 ideal = _idealSqrt();
        if (ideal < TickMath.MIN_SQRT_PRICE || ideal >= TickMath.MAX_SQRT_PRICE) return;
        int24 center = TickMath.getTickAtSqrtPrice(ideal);
        int24 t = center + int24(off % 200);
        if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) return;

        uint160 sp = TickMath.getSqrtPriceAtTick(t);
        PoolKey memory key = _poolAt(sp);
        (Outcome o,) = _check(key);
        if (o == Outcome.NoOpinion || o == Outcome.BareRevert || o == Outcome.Panic) return;

        uint256 exact = _exactDevBpsX18(sp);
        bool shouldPass = exact <= uint256(SPOT_DEV_BPS) * 1e18;
        if (o == Outcome.Enforced) {
            assertLe(exact, uint256(SPOT_DEV_BPS) * 1e18 + 1e18, "accepted a price outside tolerance");
        } else {
            assertTrue(!shouldPass || exact + 1e18 >= uint256(SPOT_DEV_BPS) * 1e18, "rejected a price inside tolerance");
        }
    }

    // ─────────────────────────── 3. tick extremes ───────────────────────────

    function test_extremeTicks_behaviour() public {
        int24[6] memory ticks =
            [TickMath.MIN_TICK, TickMath.MIN_TICK + 1, -400_000, 400_000, TickMath.MAX_TICK - 2, TickMath.MAX_TICK - 1];
        for (uint256 k = 0; k < ticks.length; k++) {
            _configure(18, 18, 8, 8, 1e8, 1e8);
            PoolKey memory key = _poolAtTick(ticks[k]);
            (Outcome o,) = _check(key);
            console2.log("tick:", int256(ticks[k]));
            console2.log("  outcome:", uint256(o));
        }
    }

    /// @notice MAX_TOKEN_DECIMALS = 36 is *not* safe on every path: with a wide decimal gap the
    /// `poolPrice` mulDiv result exceeds uint256 and `FullMath.mulDiv` reverts with **empty returndata**
    /// — neither `SpotPriceOutOfBounds` nor the documented "no opinion" `false`.
    function test_MAX_TOKEN_DECIMALS_overflowsAtHighTicks() public {
        _configure(36, 0, 8, 8, 1e8, 1e8);
        // poolPrice == humanPrice * 1e18, so it overflows once humanPrice > ~1.16e59, i.e.
        // rawPrice > 1.16e59 / 1e36 = 1.16e23 -> tick ~ 531_000, far inside MAX_TICK.
        PoolKey memory key = _poolAtTick(600_000);
        (Outcome o,) = _check(key);
        assertEq(uint256(o), uint256(Outcome.BareRevert), "expected FullMath's bare require() revert");

        // Find the first tick that breaks, by bisection, and report it.
        int24 lo = 0;
        int24 hi = 600_000;
        while (hi - lo > 1) {
            int24 mid = (lo + hi) / 2;
            PoolKey memory k2 = _poolAtTick(mid);
            (Outcome om,) = _check(k2);
            if (om == Outcome.BareRevert) hi = mid;
            else lo = mid;
        }
        console2.log("td0=36 td1=0: first overflowing tick", int256(hi));
        assertLt(hi, TickMath.MAX_TICK, "overflow is reachable well inside the legal tick range");
    }

    /// @notice The same for a decimals pair that is only *moderately* wide.
    function test_overflowBoundary_byDecimalGap() public {
        uint8[6] memory gaps = [0, 6, 12, 18, 27, 36];
        for (uint256 g = 0; g < gaps.length; g++) {
            _configure(gaps[g], 0, 8, 8, 1e8, 1e8);
            PoolKey memory key = _poolAtTick(TickMath.MAX_TICK - 1);
            (Outcome o,) = _check(key);
            console2.log("td0:", uint256(gaps[g]));
            console2.log("  outcome at MAX_TICK:", uint256(o));
        }
    }

    // ─────────────────────────── 4. arithmetic panics ───────────────────────────

    /// @notice `a1 * (10 ** fd0)` on line 292 is a plain checked multiplication, not a `mulDiv`. A large
    /// (misbehaving / compromised / newly-decimalled) feed answer turns the gate from "no opinion" into a
    /// hard `Panic(0x11)` — the whole spot path, and therefore every operator add, bricks.
    function test_panic_refPriceDenominatorOverflows() public {
        _configure(18, 18, 18, 8, 1e8, type(uint256).max / 1e17); // a1 * 10**18 overflows
        PoolKey memory key = _poolAtTick(0);
        (Outcome o, bytes memory data) = _check(key);
        assertEq(uint256(o), uint256(Outcome.Panic), "expected an arithmetic panic");
        assertEq(abi.decode(_slice(data), (uint256)), 0x11, "panic code 0x11 (over/underflow)");
    }

    /// @notice `(10 ** fd1) * WAD` on the same line overflows for `fd1 >= 60`. `feedDecimals` is read
    /// straight off the aggregator and is never bounded (unlike `tokenDecimals`).
    function test_panic_feedDecimalsUnbounded() public {
        _configure(18, 18, 8, 60, 1e8, 1e8);
        PoolKey memory key = _poolAtTick(0);
        (Outcome o,) = _check(key);
        assertEq(uint256(o), uint256(Outcome.Panic), "10 ** fd1 * WAD overflows for fd1 >= 60");
    }

    function _slice(bytes memory d) internal pure returns (bytes memory out) {
        out = new bytes(d.length - 4);
        for (uint256 i = 4; i < d.length; i++) {
            out[i - 4] = d[i];
        }
    }

    // ─────────────────────────── 5. asymmetry of |pool-ref|/ref ───────────────────────────

    /// @notice The deviation is normalised by `refPrice`, so the corridor is symmetric in *linear* terms
    /// but not in multiplicative ones: `+t` upward vs `1/(1-t)` downward. Measured as the widest tick
    /// accepted on each side.
    function test_asymmetry_upVsDown() public {
        _measureCorridor(SPOT_DEV_BPS);
        _measureCorridor(CAP_BPS);
    }

    function _measureCorridor(uint16 tol) internal {
        oracle.setMaxSpotDeviationBps(tol);
        _configure(18, 18, 8, 8, 1e8, 1e8);

        int24 up = 0;
        while (up < 20_000) {
            PoolKey memory key = _poolAtTick(up + 1);
            (Outcome o,) = _check(key);
            if (o != Outcome.Enforced) break;
            up++;
        }
        int24 down = 0;
        while (down > -20_000) {
            PoolKey memory key = _poolAtTick(down - 1);
            (Outcome o,) = _check(key);
            if (o != Outcome.Enforced) break;
            down--;
        }
        console2.log("tolerance bps:", uint256(tol));
        console2.log("  widest tick accepted up:", int256(up));
        console2.log("  widest tick accepted down:", int256(down));
        // Report the multiplicative widths in bps via the exact model.
        console2.log("  exact dev at the up edge  (bps x1e18):", _exactDevBpsX18(TickMath.getSqrtPriceAtTick(up)));
        console2.log("  exact dev at the down edge(bps x1e18):", _exactDevBpsX18(TickMath.getSqrtPriceAtTick(down)));
        oracle.setMaxSpotDeviationBps(SPOT_DEV_BPS);
    }

    // ─────────────────────────── 6. the fail-open the quantisation buys ───────────────────────────

    /// @notice **The finding.** `priceX96 = mulDiv(sqrtP, sqrtP, Q96)` truncates to an integer. Its
    /// resolution is `1 / priceX96` relative, and `priceX96 = humanPrice * 10^(td1-td0) * 2^96`, so a
    /// wide decimal gap combined with a very small human price makes the gate's resolution *coarser than
    /// its own tolerance*. Truncation is always downward, so an over-priced pool is dragged into the
    /// corridor: the operator gets exactly the skewed add H-1 was meant to stop.
    ///
    /// Ordinary decimals: currency0 with 18, currency1 with 6 (a USDC-quoted micro-cap).
    function test_failOpen_quantisation_18v6() public {
        // c0 at $1e-16, c1 (6 decimals) at $1 -> humanPrice = 1e-16, priceX96 ~ 7.9
        _configure(18, 6, 18, 8, 1e2, 1e8); // a0 = 100 with 18 feed decimals = $1e-16
        uint160 ideal = _idealSqrt();
        int24 center = TickMath.getTickAtSqrtPrice(ideal);

        int24 worst = center;
        uint256 worstExact;
        for (int24 t = center; t < center + 2_000; t++) {
            PoolKey memory key = _poolAtTick(t);
            (Outcome o,) = _check(key);
            if (o != Outcome.Enforced) continue;
            uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
            if (e > worstExact) {
                worstExact = e;
                worst = t;
            }
        }
        console2.log("18/6 decimals, $1e-16 token: worst accepted tick", int256(worst - center));
        console2.log("  exact deviation accepted (bps x1e18):", worstExact);
        console2.log("  configured tolerance (bps x1e18):", uint256(SPOT_DEV_BPS) * 1e18);
        assertLe(worstExact, uint256(SPOT_DEV_BPS) * 1e18 + 1e18, "accepted a price outside the spot tolerance");
    }

    /// @notice The same defect at the decimals the contract explicitly permits (`MAX_TOKEN_DECIMALS`),
    /// with a completely ordinary price of ~1.
    function test_failOpen_quantisation_27v0() public {
        _configure(27, 0, 8, 8, 1e8, 1e8); // both $1 -> humanPrice = 1, priceX96 ~ 79
        uint160 ideal = _idealSqrt();
        int24 center = TickMath.getTickAtSqrtPrice(ideal);

        uint256 worstExact;
        int24 worst;
        for (int24 t = center - 500; t < center + 500; t++) {
            PoolKey memory key = _poolAtTick(t);
            (Outcome o,) = _check(key);
            if (o != Outcome.Enforced) continue;
            uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
            if (e > worstExact) {
                worstExact = e;
                worst = t - center;
            }
        }
        console2.log("27/0 decimals, price 1: worst accepted tick offset", int256(worst));
        console2.log("  exact deviation accepted (bps x1e18):", worstExact);
        assertLe(worstExact, uint256(SPOT_DEV_BPS) * 1e18 + 1e18, "accepted a price outside the spot tolerance");
    }

    /// @notice And the availability side of the same coin: the pool sits *on* the reference but the
    /// quantised comparison puts it outside.
    function test_failClosed_quantisation() public {
        _configure(27, 0, 8, 8, 1e8, 1e8);
        uint160 ideal = _idealSqrt();
        int24 center = TickMath.getTickAtSqrtPrice(ideal);
        uint256 worstMargin;
        int24 worst;
        for (int24 t = center - 500; t < center + 500; t++) {
            uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
            if (e > uint256(SPOT_DEV_BPS) * 1e18) continue; // genuinely outside; a revert is correct
            PoolKey memory key = _poolAtTick(t);
            (Outcome o,) = _check(key);
            if (o == Outcome.SpotRevert) {
                uint256 margin = uint256(SPOT_DEV_BPS) * 1e18 - e;
                if (margin > worstMargin) {
                    worstMargin = margin;
                    worst = t - center;
                }
            }
        }
        console2.log("worst in-tolerance price rejected: tick offset", int256(worst));
        console2.log("  its exact deviation was only (bps x1e18):", uint256(SPOT_DEV_BPS) * 1e18 - worstMargin);
        assertEq(worstMargin, 0, "rejected a price that is inside the tolerance");
    }

    /// @notice The counterexample the fuzzer found on its own: td0=18, td1=6, fd0=18, fd1=6, a0=7440,
    /// a1=1e8 — i.e. currency0 (18 dec) at $7.44e-15 and currency1 (6 dec) at $100. `priceX96` lands on
    /// ~5, so one integer step of `priceX96` is ~20% of the price and the 50 bps corridor is meaningless
    /// in both directions.
    function test_fuzzCounterexample_18v6() public {
        _configure(18, 6, 18, 6, 7440, 1e8);
        uint160 ideal = _idealSqrt();
        int24 center = TickMath.getTickAtSqrtPrice(ideal);
        uint256 acceptedMax;
        uint256 rejectedMin = type(uint256).max;
        for (int24 t = center - 2200; t <= center + 2200; t += 11) {
            uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
            PoolKey memory key = _poolAtTick(t);
            (Outcome o,) = _check(key);
            if (o == Outcome.Enforced && e > acceptedMax) acceptedMax = e;
            if (o == Outcome.SpotRevert && e < rejectedMin) rejectedMin = e;
        }
        console2.log("18/6, $7.44e-15 token: largest exact deviation ACCEPTED (bps x1e18):", acceptedMax);
        console2.log("                       smallest exact deviation REJECTED (bps x1e18):", rejectedMin);
        console2.log("                       configured tolerance (bps x1e18):", uint256(SPOT_DEV_BPS) * 1e18);
        assertLe(acceptedMax, uint256(SPOT_DEV_BPS) * 1e18 + 1e18, "accepted outside tolerance");
        assertGe(rejectedMin, uint256(SPOT_DEV_BPS) * 1e18, "rejected inside tolerance");
    }

    /// @notice Characterises exactly when the gate loses resolution. `priceX96 = mulDiv(sqrtP, sqrtP,
    /// Q96)` is an integer, so the gate's resolution is `1e4 / priceX96` bps, and
    /// `priceX96 = humanPrice * 10^(td1-td0) * 2^96`. Holding `priceX96 ~ 79` constant while varying the
    /// decimal gap `d = td0 - td1` shows the resolution is ~126 bps for **every** `d >= 9` — 2.5x the
    /// 50 bps tolerance — while `d < 9` instead degenerates to `poolPrice == 0` (no opinion).
    function test_resolutionScan_byDecimalGap() public {
        uint8[9] memory gaps = [6, 8, 9, 10, 12, 18, 27, 30, 36];
        for (uint256 g = 0; g < gaps.length; g++) {
            _scanGap(gaps[g]);
        }
    }

    function _scanGap(uint8 d) internal {
        // ref = 10^(d-27) so that priceX96 == 1e-27 * 2^96 ~= 79 for every gap.
        uint256 a0 = d >= 9 ? 10 ** (uint256(d) - 9) : 1;
        uint256 a1 = d >= 9 ? 1e18 : 10 ** (9 - uint256(d)) * 1e18;
        _configure(d, 0, 18, 18, a0, a1);
        uint160 ideal = _idealSqrt();
        if (ideal < TickMath.MIN_SQRT_PRICE || ideal >= TickMath.MAX_SQRT_PRICE) {
            console2.log("decimal gap (unreachable sqrt price):", uint256(d));
            return;
        }
        int24 center = TickMath.getTickAtSqrtPrice(ideal);
        uint256 acceptedMax;
        uint256 nEnforced;
        uint256 nNoOpinion;
        for (int24 t = center - 200; t <= center + 200; t += 4) {
            PoolKey memory key = _poolAtTick(t);
            (Outcome o,) = _check(key);
            if (o == Outcome.NoOpinion) {
                nNoOpinion++;
                continue;
            }
            if (o != Outcome.Enforced) continue;
            nEnforced++;
            uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
            if (e > acceptedMax) acceptedMax = e;
        }
        console2.log("decimal gap td0-td1:", uint256(d));
        console2.log("   ticks accepted (of 101 probed):", nEnforced);
        console2.log("   no-opinion probes:", nNoOpinion);
        console2.log("   largest exact deviation accepted (bps x1e18):", acceptedMax);
    }

    /// @notice The *decimals-independent* half of the same defect. `poolPrice` and `refPrice` are both
    /// integers scaled by 1e18, i.e. the human price in WAD, so the comparison's resolution is
    /// `1e4 / (humanPrice * 1e18)` bps no matter what the token decimals are. Both pool assets at 18
    /// decimals; only the USD price ratio between them moves.
    function test_resolutionScan_byPriceRatio() public {
        // usd0/usd1 = a0 / 1e18 with fd0 = fd1 = 18 and a1 = 1e18.
        uint256[7] memory a0s = [uint256(1e18), 1e12, 1e6, 1e4, 1e3, 1e2, 1e1];
        for (uint256 i = 0; i < a0s.length; i++) {
            _scanRatio(a0s[i]);
        }
    }

    function _scanRatio(uint256 a0) internal {
        _configure(18, 18, 18, 18, a0, 1e18);
        uint160 ideal = _idealSqrt();
        if (ideal < TickMath.MIN_SQRT_PRICE || ideal >= TickMath.MAX_SQRT_PRICE) return;
        int24 center = TickMath.getTickAtSqrtPrice(ideal);
        uint256 acceptedMax;
        uint256 rejectedMin = type(uint256).max;
        uint256 nEnforced;
        for (int24 t = center - 300; t <= center + 300; t += 3) {
            PoolKey memory key = _poolAtTick(t);
            (Outcome o,) = _check(key);
            if (o != Outcome.Enforced && o != Outcome.SpotRevert) continue;
            uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
            if (o == Outcome.Enforced) {
                nEnforced++;
                if (e > acceptedMax) acceptedMax = e;
            } else if (e < rejectedMin) {
                rejectedMin = e;
            }
        }
        console2.log("usd0/usd1 numerator a0 (a1 = 1e18, both feeds 18 dec):", a0);
        console2.log("   probes accepted:", nEnforced);
        console2.log("   largest exact deviation ACCEPTED (bps x1e18):", acceptedMax);
        console2.log("   smallest exact deviation REJECTED (bps x1e18):", rejectedMin);
    }

    // ───────── self-contained repros (no FFI, liftable as-is) ─────────

    /// @notice FAIL-OPEN, no FFI. currency0 with 27 decimals, currency1 with 0 decimals, both quoted at
    /// exactly $1 so the reference price is 1.0 and the tolerance is 50 bps. The pool is initialised
    /// 0.965% above 1.0 — nearly twice the tolerance — and the gate vouches for it, because
    /// `priceX96 = mulDiv(sqrtP, sqrtP, Q96)` is only 79 at this price and one integer step of it is
    /// 1.26% of the price. src/oracle/ChainlinkPriceOracle.sol:289.
    function test_repro_failOpen_noFfi() public {
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 27);
        oracle.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 0);

        int24 parityTick = -621_730; // 1.0001^-621730 == 1e-27 == the raw price of a 1.0 human price
        // sanity: the parity tick itself is inside the corridor and is accepted
        assertTrue(oracle.check(_poolAtTick(parityTick), true, 0, 0), "parity accepted");

        // +97 ticks == pool price 1.00965 vs a reference of exactly 1.0 -> 96.5 bps, tolerance is 50.
        PoolKey memory skewed = _poolAtTick(parityTick + 97);
        assertTrue(oracle.check(skewed, true, 0, 0), "FAIL-OPEN: 96.5 bps accepted against a 50 bps gate");
    }

    /// @notice FAIL-CLOSED, no FFI. Same pair; the pool sits 28.9 bps from the reference — comfortably
    /// inside the 50 bps corridor — and the gate reverts `SpotPriceOutOfBounds`, so no operator add can
    /// ever go through on this pair.
    function test_repro_failClosed_noFfi() public {
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 27);
        oracle.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 3600, 0);
        PoolKey memory key = _poolAtTick(-621_730 - 28); // 1.0001^-28 = -28.0 bps
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        oracle.check(key, true, 0, 0);
    }

    // ─────────────────────────── 7. rounding at ordinary decimals ───────────────────────────

    /// @notice Baseline: at realistic decimals and prices the rounding error is negligible. Reported so
    /// the negative result is quantified rather than assumed.
    function test_roundingError_ordinaryDecimals() public {
        uint8[6] memory pairs0 = [18, 18, 6, 8, 18, 6];
        uint8[6] memory pairs1 = [18, 6, 18, 18, 8, 6];
        uint256[6] memory answers0 = [uint256(2000e8), 2000e8, 1e8, 60000e8, 1e6, 1e10];
        uint256 worst;
        for (uint256 p = 0; p < 6; p++) {
            _configure(pairs0[p], pairs1[p], 8, 8, answers0[p], 1e8);
            uint160 ideal = _idealSqrt();
            int24 center = TickMath.getTickAtSqrtPrice(ideal);
            for (int24 t = center - 60; t <= center + 60; t++) {
                uint256 e = _exactDevBpsX18(TickMath.getSqrtPriceAtTick(t));
                PoolKey memory key = _poolAtTick(t);
                (Outcome o,) = _check(key);
                bool pass = o == Outcome.Enforced;
                bool shouldPass = e <= uint256(SPOT_DEV_BPS) * 1e18;
                if (pass != shouldPass) {
                    uint256 err = e > uint256(SPOT_DEV_BPS) * 1e18
                        ? e - uint256(SPOT_DEV_BPS) * 1e18
                        : uint256(SPOT_DEV_BPS) * 1e18 - e;
                    if (err > worst) worst = err;
                }
            }
        }
        console2.log("worst boundary disagreement at ordinary decimals (bps x1e18):", worst);
        assertLe(worst, 1e18, "boundary error should stay under 1 bps at ordinary decimals");
    }
}
