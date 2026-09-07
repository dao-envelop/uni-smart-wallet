// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {UniLens} from "../src/UniLens.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";
import {TwoInOneTx} from "./helpers/Mocks.sol";

/// @notice Regressions for task_054, against the two HIGH findings of the fix review.
///
/// The exploits these replace are preserved verbatim under `audits/2026-09-04/fix-review/poc/`; they
/// ran against this repo and measured 24.84% drained in one transaction (R-2) and 44.997% through a
/// hook in one approved call (R-1). What is pinned here is that each of those is now refused, and — as
/// important — that the refusals are narrow: an operator working a sane pool one call at a time is
/// unaffected, or the guards would be indistinguishable from switching operators off.
contract Task054Regressions is RedTeamBase {
    /// @dev The drain cycle needs a range parked between the reference and the edge of the tolerance
    /// band. Its midpoint is then ~49 bps from the reference, and that distance is exactly what the
    /// oracle now refuses — on any pool, at any tick spacing, without taking the pool away.
    function test_R2_positionOffReference_refusesTheParkedRange() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18);
        _openAsOwner(-1, 0, 1_000e18); // the owner may still work the pool

        _swapTo(49); // skew to the edge of the 50 bps band, as the exploit did
        vm.expectPartialRevert(ChainlinkPriceOracle.PositionOffReference.selector);
        _recenterAsBot(48, 49);
    }

    /// @dev A pool whose lattice is coarser than the tolerance passes the rule — no range fits in the
    /// corridor there, which is the point. The operator can work it, once per transaction.
    function test_R2_operatorWorksACoarsePoolOnce() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        _recenterAsBot(-120, 120);
        assertEq(mgr.positionOf(SALT).tickLower, int24(-120), "one operator recenter goes through");
    }

    /// @dev The loop itself. Sixty of these in one transaction took 24.84%; the second is now refused,
    /// so an attacker has to pay for a fresh transaction — and leave a block for someone to react in.
    function test_R2_secondOperatorOpInTheSameTxIsRefused() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        TwoInOneTx batch = new TwoInOneTx();
        vm.prank(owner);
        mgr.setOperator(address(batch), true);

        vm.expectRevert(SingletonNFTOwned.OperatorOpsPerTx.selector);
        batch.run(
            address(mgr),
            abi.encodeCall(mgr.recenter, (_ownerRecenter(-120, 120))),
            abi.encodeCall(mgr.recenter, (_ownerRecenter(-180, 180)))
        );
    }

    /// @dev The owner is not rate-limited — the limit is about a delegated key, not about the manager.
    function test_R2_ownerIsNotRateLimited() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        vm.startPrank(owner);
        mgr.recenter(_ownerRecenter(-120, 120));
        mgr.recenter(_ownerRecenter(-180, 180));
        vm.stopPrank();
        assertEq(mgr.positionOf(SALT).tickLower, int24(-180), "both owner recenters applied");
    }

    /// @dev The value the loop used to extract, measured on a pool it can still reach. One operation is
    /// all a transaction now holds, so this is the whole per-transaction exposure.
    function test_R2_singleOperationExposureIsBounded() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        uint256 before = _managerValue();
        _swapTo(40); // inside the 50 bps band: the oracle still vouches
        _recenterAsBot(-60, 60);
        _swapTo(0);

        uint256 lostBps = before > _managerValue() ? (before - _managerValue()) * 10_000 / before : 0;
        console2.log("one vouched-for operation, coarse pool - manager loss (bps):", lostBps);
        assertLt(lostBps, 100, "a single operation cannot take a percent");
    }

    /// @dev What a UI reads to explain a refusal: both tolerances, from the same call.
    function test_R2_lensSurfacesBothTolerances() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18);
        UniLens lens = new UniLens();
        UniLens.OracleStatus memory st = lens.oracleStatus(address(mgr));
        assertEq(st.maxSpotDeviationBps, 50, "spot tolerance");
        assertEq(st.maxMidOffsetBps, 10, "midpoint tolerance");
    }

    /// @dev The product win the midpoint rule buys over a tick-spacing ban: on the very pool the drain
    /// used — spacing 1 — an honest operator recenter after a REAL market move goes through. Both the
    /// reference and the pool moved, so a range centred on the new price is centred on the reference.
    /// The freed capital is one-sided after such a move, so the honest flow rebalances with the
    /// (oracle-gated) pre-swap and re-adds two-sided; a swapless one-sided re-add wider than 2*theta
    /// is refused, since by geometry it is the parked range the rule exists to stop.
    function test_R2_honestRecenterAfterMarketMove_passesOnSpacingOne() public {
        _boot(100, 1, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        // The market moves +3%: the reference follows (currency0 now worth $1.03), and so does the pool.
        vm.prank(oracle.owner());
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1.03e8), block.timestamp)), 365 days, 18);
        _swapTo(296); // ln(1.03)/ln(1.0001) ~ 295.6

        // Operator: rebalance the freed currency1 into currency0 at the (fair) pool price, then re-add
        // centred on the new price. Both halves are oracle-vouched.
        // A small rebalance: the harness pool is thin (4_000e18 of liquidity). 20e18 already moved the
        // pool ~1% and tripped the SPOT gate on the operation's own pre-swap — the self-lockout the
        // review named R-7, working as designed. 5e18 keeps the impact inside the band.
        _recenterWithSwap(bot, 236, 356, false, 5e18);
        assertEq(mgr.positionOf(SALT).tickLower, int24(236), "operator recentred on the moved market");
    }

    /// @dev Step 0 of the plan: the formula behind the gate, measured. With the midpoint bounded at
    /// theta, the attacker's best legal parking is a razor whose midpoint sits exactly theta from the
    /// reference; sweeping the price through it converts the principal at that price. Expected loss:
    /// `theta - fee`, minus half a tick of lattice rounding. Independent of tick spacing and width.
    function test_R2_takeIsThetaMinusFee() public {
        uint16[3] memory thetas = [uint16(5), uint16(10), uint16(20)];
        for (uint256 i = 0; i < thetas.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 lost = _measureTake(thetas[i]);
            console2.log("theta (bps)", thetas[i], "measured take (bps)", lost);
            // theta - fee(1) - lattice(0.5), floored: 3, 8, 18
            assertGe(lost, uint256(thetas[i]) - 2, "take at least theta - fee - lattice");
            assertLe(lost, uint256(thetas[i]), "take never above theta");
            vm.revertToState(snap);
        }
    }

    /// @dev Width buys the attacker nothing under the midpoint rule: a wide range centred at theta is
    /// two-sided at the skewed price, and the sweep converts its middle at the fair price.
    function test_R2_wideRangeAtThetaTakesNothing() public {
        _boot(100, 1, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);
        vm.prank(oracle.owner());
        oracle.setMaxMidOffsetBps(10);

        uint256 before = _managerValue();
        _swapTo(49);
        _recenterAsBot(-90, 110); // mid = +10 = theta, width 200, two-sided at the skewed price
        _swapTo(-49);
        uint256 after_ = _managerValue();
        uint256 lost = before > after_ ? (before - after_) * 10_000 / before : 0;
        console2.log("wide range at theta - manager loss (bps)", lost);
        assertLe(lost, 2, "a wide centred range converts at the fair price");
    }

    function _measureTake(uint16 theta) internal returns (uint256 lostBps) {
        _boot(100, 1, 4_000e18, 0, 1_000e18); // 0.01% fee, spacing 1, thin pool
        _openAsOwner(-1, 0, 1_000e18);
        vm.prank(oracle.owner());
        oracle.setMaxMidOffsetBps(theta);

        uint256 before = _managerValue();
        _swapTo(49); // inside the 50 bps spot band: the oracle vouches for the pool
        int24 t = int24(uint24(theta));
        _recenterAsBot(t - 1, t); // razor whose midpoint is theta - 0.5 from the reference
        _swapTo(-49); // drag the price through it
        uint256 after_ = _managerValue();
        lostBps = before > after_ ? (before - after_) * 10_000 / before : 0;
    }

    function _ownerRecenter(int24 tl, int24 tu) internal pure returns (VolatileLPManager.RecenterParams memory) {
        return VolatileLPManager.RecenterParams({
            salt: SALT,
            newTickLower: tl,
            newTickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            minLiquidity: 0
        });
    }
}
