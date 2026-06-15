// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Helpers used by UniSmartWallet for V4 position math:
///   - tick-spacing snapping for operator-supplied ranges
///   - tick-range / spacing validation
///   - a thin wrapper around v4-periphery's LiquidityAmounts.getLiquidityForAmounts
///     so the wallet doesn't need to import LiquidityAmounts directly.
library PositionMath {
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error TickNotMultipleOfSpacing(int24 tick, int24 spacing);
    error TickOutOfRange(int24 tick);

    /// @notice Round `tick` DOWN to the nearest multiple of `spacing`.
    function snapTickLower(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @notice Round `tick` UP to the nearest multiple of `spacing`.
    function snapTickUpper(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }

    /// @notice Revert unless [tickLower, tickUpper) is a valid range for `spacing`:
    ///   - tickLower < tickUpper
    ///   - both ticks are multiples of spacing
    ///   - both ticks are within the spacing-adjusted usable bounds
    /// @dev `public` so the bytecode is deployed once as a linked library, keeping the
    /// contracts that use it (UniSmartWallet / StableLPManager) under the EIP-170 size limit.
    function requireValidTickRange(int24 tickLower, int24 tickUpper, int24 spacing) public pure {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        if (tickLower % spacing != 0) revert TickNotMultipleOfSpacing(tickLower, spacing);
        if (tickUpper % spacing != 0) revert TickNotMultipleOfSpacing(tickUpper, spacing);
        if (tickLower < TickMath.minUsableTick(spacing)) revert TickOutOfRange(tickLower);
        if (tickUpper > TickMath.maxUsableTick(spacing)) revert TickOutOfRange(tickUpper);
    }

    /// @notice Thin pass-through to LiquidityAmounts.getLiquidityForAmounts.
    /// @dev `public` (linked library) — see {requireValidTickRange}.
    function liquidityFromAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) public pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }
}
