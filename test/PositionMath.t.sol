// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionMath} from "../src/lib/PositionMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Library internal calls don't cross a call boundary, so vm.expectRevert can't see them.
/// Use this thin wrapper to route revert-asserting tests through an external call.
contract PositionMathWrapper {
    function snapTickLower(int24 t, int24 s) external pure returns (int24) {
        return PositionMath.snapTickLower(t, s);
    }

    function snapTickUpper(int24 t, int24 s) external pure returns (int24) {
        return PositionMath.snapTickUpper(t, s);
    }

    function requireValidTickRange(int24 lo, int24 hi, int24 s) external pure {
        PositionMath.requireValidTickRange(lo, hi, s);
    }

    function liquidityFromAmounts(uint160 sp, int24 lo, int24 hi, uint256 a0, uint256 a1)
        external
        pure
        returns (uint128)
    {
        return PositionMath.liquidityFromAmounts(sp, lo, hi, a0, a1);
    }
}

contract PositionMathTest is Test {
    int24 internal constant SPACING = 60;
    PositionMathWrapper internal pm;

    function setUp() public {
        pm = new PositionMathWrapper();
    }

    // ────────── snapTickLower ──────────

    function test_snapTickLower_alreadyAligned() public pure {
        assertEq(PositionMath.snapTickLower(0, SPACING), 0);
        assertEq(PositionMath.snapTickLower(60, SPACING), 60);
        assertEq(PositionMath.snapTickLower(-60, SPACING), -60);
    }

    function test_snapTickLower_roundsDown() public pure {
        assertEq(PositionMath.snapTickLower(75, SPACING), 60);
        assertEq(PositionMath.snapTickLower(119, SPACING), 60);
        assertEq(PositionMath.snapTickLower(-1, SPACING), -60);
        assertEq(PositionMath.snapTickLower(-119, SPACING), -120);
    }

    // ────────── snapTickUpper ──────────

    function test_snapTickUpper_alreadyAligned() public pure {
        assertEq(PositionMath.snapTickUpper(0, SPACING), 0);
        assertEq(PositionMath.snapTickUpper(60, SPACING), 60);
        assertEq(PositionMath.snapTickUpper(-60, SPACING), -60);
    }

    function test_snapTickUpper_roundsUp() public pure {
        assertEq(PositionMath.snapTickUpper(45, SPACING), 60);
        assertEq(PositionMath.snapTickUpper(1, SPACING), 60);
        assertEq(PositionMath.snapTickUpper(-59, SPACING), 0);
        assertEq(PositionMath.snapTickUpper(-1, SPACING), 0);
    }

    // ────────── requireValidTickRange ──────────

    function test_requireValidTickRange_acceptsAlignedRange() public view {
        pm.requireValidTickRange(-60, 60, SPACING);
        pm.requireValidTickRange(0, 120, SPACING);
    }

    function test_requireValidTickRange_revertsOnInverted() public {
        vm.expectRevert(abi.encodeWithSelector(PositionMath.InvalidTickRange.selector, int24(60), int24(60)));
        pm.requireValidTickRange(60, 60, SPACING);

        vm.expectRevert(abi.encodeWithSelector(PositionMath.InvalidTickRange.selector, int24(120), int24(60)));
        pm.requireValidTickRange(120, 60, SPACING);
    }

    function test_requireValidTickRange_revertsOnUnalignedLower() public {
        vm.expectRevert(abi.encodeWithSelector(PositionMath.TickNotMultipleOfSpacing.selector, int24(45), SPACING));
        pm.requireValidTickRange(45, 120, SPACING);
    }

    function test_requireValidTickRange_revertsOnUnalignedUpper() public {
        vm.expectRevert(abi.encodeWithSelector(PositionMath.TickNotMultipleOfSpacing.selector, int24(75), SPACING));
        pm.requireValidTickRange(0, 75, SPACING);
    }

    function test_requireValidTickRange_revertsOnOutOfRange() public {
        int24 belowMin = TickMath.minUsableTick(SPACING) - SPACING;
        int24 aboveMax = TickMath.maxUsableTick(SPACING) + SPACING;

        vm.expectRevert(abi.encodeWithSelector(PositionMath.TickOutOfRange.selector, belowMin));
        pm.requireValidTickRange(belowMin, 60, SPACING);

        vm.expectRevert(abi.encodeWithSelector(PositionMath.TickOutOfRange.selector, aboveMax));
        pm.requireValidTickRange(-60, aboveMax, SPACING);
    }

    // ────────── liquidityFromAmounts ──────────

    function test_liquidityFromAmounts_symmetricRangeNonZero() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);
        uint128 L = PositionMath.liquidityFromAmounts(sqrtP, -60, 60, 1e18, 1e18);
        assertGt(L, 0);
    }

    function test_liquidityFromAmounts_zeroAmountsReturnsZero() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);
        assertEq(PositionMath.liquidityFromAmounts(sqrtP, -60, 60, 0, 0), 0);
    }
}
