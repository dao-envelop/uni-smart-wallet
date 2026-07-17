// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPriceOracle
/// @notice Pluggable price guard for a manager's on-chain swaps. The manager calls `check` right
/// after each swap; an implementation reverts (its own `PriceOutOfBounds`-style error) when the
/// realized price (`amountOut / amountIn`) deviates beyond its tolerance from a trusted reference for
/// `key`, and **returns without reverting when it has no fresh reference** for the pool — so the
/// caller's own `amountMax` / `minAmountOut` remain the only guard (graceful fallback, never blocks a
/// legitimate op). `view`: it must not mutate state.
interface IPriceOracle {
    /// @param key The pool the swap ran in.
    /// @param zeroForOne The swap direction (currency0 → currency1 when true).
    /// @param amountIn The input amount paid to the pool.
    /// @param amountOut The output amount received from the pool.
    function check(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 amountOut) external view;
}
