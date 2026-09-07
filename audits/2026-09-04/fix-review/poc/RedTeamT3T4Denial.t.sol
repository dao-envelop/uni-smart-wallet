// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice TARGET 3 (griefing / denial) and TARGET 4 (self-lockout).
///
/// The gate is fail-closed for operators and reads the pool's LIVE `slot0`. Two consequences the fix
/// did not have to answer for before it existed:
///   • anyone who can move the pool 51 bps can switch every operator liquidity op in that pool off;
///   • the operator's OWN pre-swap moves the price the add is then judged on, and the spot tolerance
///     (50 bps) is tighter than the swap tolerance (100 bps) that let the pre-swap through.
contract RedTeamT3Griefing is RedTeamBase {
    int24 internal constant OUT = 60; // 1.0001^60 = +60.2 bps — just outside the 50 bps tolerance

    /// @dev An unprivileged third party blocks every operator liquidity op in the pool.
    function test_T3a_thirdPartyBlocksOperator() public {
        _boot(100, 1, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-100, 100, 500e18);

        // Everything works while the pool sits on the reference.
        _recenterAsBot(-120, 120);

        uint256 g0 = _valueOf(griefer);
        _swapToAs(griefer, OUT); // one swap, no privileges of any kind
        uint256 skewCost = g0 - _valueOf(griefer);

        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.recenter(_plainRecenter(-60, 60));

        // ... and allocate of idle capital is dead too.
        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.allocate(_one(_leg(bytes32(uint256(9)), -60, 60, 100e18, 100e18)));

        console2.log("--- T3a: unprivileged third party locks the operator out ---");
        console2.log("griefer mark-to-market cost of the skew (wei)", skewCost);
        console2.log("  as a fraction of the manager portfolio (bps)", skewCost * 10_000 / 2_000e18);

        // The owner is unaffected — they bypass `_guardSwap` entirely.
        vm.prank(owner);
        mgr.recenter(_plainRecenter(-60, 60));
        assertEq(mgr.positionOf(SALT).tickLower, int24(-60), "the owner can still act");
    }

    /// @dev The cheap form: sandwich the operator's transaction. Skew, let the op revert, unskew. What
    /// the griefer actually pays is the round trip, not the skew.
    function test_T3b_sandwichCost() public {
        console2.log("--- T3b: cost of ONE blocked operator transaction (skew + unskew) ---");
        uint256[3] memory depths = [uint256(4_000e18), 400_000e18, 40_000_000e18];
        for (uint256 i = 0; i < depths.length; ++i) {
            _boot(100, 1, depths[i], 1_000e18, 1_000e18);
            _openAsOwner(-100, 100, 500e18);
            uint256 g0 = _valueOf(griefer);

            _swapToAs(griefer, OUT); // front-run
            vm.prank(bot);
            vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
            mgr.recenter(_plainRecenter(-60, 60));
            _swapToAs(griefer, 0); // back-run

            console2.log("  pool liquidity          ", depths[i]);
            console2.log("     griefer net cost (wei)", g0 - _valueOf(griefer));
        }
    }

    /// @dev Same lever on a 0.3 % pool: the fee tier is what the cost scales with.
    function test_T3c_sandwichCostAcrossFeeTiers() public {
        console2.log("--- T3c: sandwich cost across fee tiers (pool liquidity 400_000e18) ---");
        uint24[3] memory fees = [uint24(100), uint24(500), uint24(3000)];
        int24[3] memory spacings = [int24(1), int24(10), int24(60)];
        for (uint256 i = 0; i < fees.length; ++i) {
            _boot(fees[i], spacings[i], 400_000e18, 1_000e18, 1_000e18);
            _openAsOwner(-spacings[i] * 2, spacings[i] * 2, 500e18);
            uint256 g0 = _valueOf(griefer);
            _swapToAs(griefer, 61);
            vm.prank(bot);
            vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
            mgr.recenter(_plainRecenter(-spacings[i], spacings[i]));
            _swapToAs(griefer, 0);
            console2.log("  fee (pips)              ", uint256(fees[i]));
            console2.log("     griefer net cost (wei)", g0 - _valueOf(griefer));
        }
    }

    // ────────── helpers ──────────

    function _plainRecenter(int24 tl, int24 tu) internal pure returns (VolatileLPManager.RecenterParams memory) {
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

    function _one(VolatileLPManager.VolatileAllocLeg memory l)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = l;
    }
}

/// @notice TARGET 4 — the operator's own operation locks itself out.
contract RedTeamT4SelfLockout is RedTeamBase {
    /// @dev A legitimate rebalancing pre-swap whose price impact exceeds the SPOT tolerance while its
    /// realized price is comfortably inside the SWAP tolerance. Sweeps the pre-swap size against a
    /// fixed pool depth to locate the break point.
    function test_T4a_preSwapSizeThatSelfReverts() public {
        console2.log("--- T4a: recenter with a pre-swap, pool liquidity 1_000_000e18, fee 0.01 % ---");
        uint256[6] memory sizes = [uint256(500e18), 1_000e18, 2_000e18, 2_500e18, 3_000e18, 5_000e18];
        for (uint256 i = 0; i < sizes.length; ++i) {
            _boot(100, 1, 1_000_000e18, 20_000e18, 20_000e18);
            _openAsOwner(-1000, 1000, 5_000e18);

            bool reverted;
            try this.doRecenter(sizes[i]) {}
            catch {
                reverted = true;
            }
            (, int24 t,,) = _slot0();
            console2.log("  pre-swap in (wei)       ", sizes[i]);
            console2.log("     as bps of pool liquidity", sizes[i] * 10_000 / 1_000_000e18);
            console2.log("     resulting tick        ", int256(t));
            console2.log("     recenter reverted?    ", reverted ? 1 : 0);
        }
    }

    /// @dev The asymmetry itself: for the very swap that makes the add revert, `check`'s SWAP branch
    /// still says yes. The operator is refused by a gate that its own, oracle-approved, swap tripped.
    function test_T4b_swapGatePassesWhileSpotGateRejects() public {
        _boot(100, 1, 1_000_000e18, 20_000e18, 20_000e18);
        _openAsOwner(-1000, 1000, 5_000e18);

        uint256 amountIn = 3_000e18; // 30 bps of the pool's liquidity ⇒ ~60 bps of price impact

        // 1. The identical swap, executed standalone, and judged by the oracle's SWAP branch.
        uint256 before1 = MockERC20(Currency.unwrap(c1)).balanceOf(bot);
        uint256 before0 = MockERC20(Currency.unwrap(c0)).balanceOf(bot);
        _swapExactInAs(bot, true, amountIn);
        uint256 got = MockERC20(Currency.unwrap(c1)).balanceOf(bot) - before1;
        uint256 paid = before0 - MockERC20(Currency.unwrap(c0)).balanceOf(bot);
        assertTrue(oracle.check(key, true, paid, got), "the SWAP branch vouches for this trade");
        (, int24 tAfter,,) = _slot0();

        console2.log("--- T4b: one trade, two tolerances ---");
        console2.log("  swapped in (wei)          ", paid);
        console2.log("  received (wei)            ", got);
        console2.log("  realized shortfall (bps)  ", (paid - got) * 10_000 / paid);
        console2.log("  swap tolerance (bps)      ", uint256(oracle.maxDeviationBps()));
        console2.log("  resulting tick            ", int256(tAfter));
        console2.log("  spot tolerance (bps)      ", uint256(oracle.maxSpotDeviationBps()));
        assertFalse(_spotOk(), "the SPOT branch refuses the very price that trade produced");
    }

    /// @dev The same thing reached from inside a single operator call: the recenter's own pre-swap
    /// makes the recenter's own add revert.
    function test_T4c_recenterSelfReverts() public {
        _boot(100, 1, 1_000_000e18, 20_000e18, 20_000e18);
        _openAsOwner(-1000, 1000, 5_000e18);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        this.doRecenter(3_000e18);
    }

    /// @dev The multi-leg `allocate` loop: leg 0's pre-swap moves the price for leg 1 in the SAME pool.
    /// Each leg's swap is individually small enough that the swap gate vouches for it; their sum is not.
    function test_T4d_multiLegAllocateDriftsIntoItsOwnGate() public {
        _boot(100, 1, 1_000_000e18, 20_000e18, 20_000e18);

        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](3);
        for (uint256 i = 0; i < 3; ++i) {
            legs[i] = _leg(bytes32(uint256(0x100 + i)), -1000, 1000, 1_000e18, 1_000e18);
            legs[i].zeroForOne = true;
            legs[i].swapAmountIn = 1_000e18; // 10 bps of pool liquidity each: ~20 bps of impact
            legs[i].swapPriceLimit = 4295128740; // MIN_SQRT_PRICE + 1
        }

        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.allocate(legs);

        console2.log("--- T4d: 3 legs x 1_000e18 pre-swap in one pool: the last leg is locked out ---");

        // Two legs alone stay inside the band and succeed, which pins where the boundary is.
        VolatileLPManager.VolatileAllocLeg[] memory two = new VolatileLPManager.VolatileAllocLeg[](2);
        two[0] = legs[0];
        two[1] = legs[1];
        vm.prank(bot);
        mgr.allocate(two);
        (, int24 t,,) = _slot0();
        console2.log("  tick after the 2 legs that fit", int256(t));
    }

    // ────────── helpers ──────────

    function doRecenter(uint256 amountIn) external {
        _recenterWithSwap(bot, -1000, 1000, true, amountIn);
    }

    function _slot0() internal view returns (uint160 s, int24 t, uint24 a, uint24 b) {
        return _rawSlot0();
    }

    function _spotOk() internal view returns (bool ok) {
        try oracle.check(key, true, 0, 0) returns (bool r) {
            ok = r;
        } catch {
            ok = false;
        }
    }
}
