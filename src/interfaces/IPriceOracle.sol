// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IPriceOracle
/// @notice Pluggable price guard for a manager's on-chain swaps. The manager calls `check` right after
/// each swap; an implementation **reverts** (its own `PriceOutOfBounds`-style error) when the realized
/// price (`amountOut / amountIn`) deviates beyond its tolerance from a trusted reference for `key`.
/// @dev `check` returns whether it actually **enforced** a bound: `true` when it had a fresh reference
/// and the price was in-bounds (out-of-bounds reverts before returning), `false` when it had **no fresh
/// reference** for the pool and therefore expressed no opinion. The manager uses this to decide per
/// caller: an NFT-owner swap proceeds regardless (full freedom); an operator swap is **rejected** unless
/// `check` returned `true` (fail-closed — an operator may only swap at an oracle-vouched price). `view`:
/// it must not mutate state.
interface IPriceOracle {
    /// @param key The pool the swap ran in.
    /// @param zeroForOne The swap direction (currency0 → currency1 when true).
    /// @param amountIn The input amount paid to the pool.
    /// @param amountOut The output amount received from the pool.
    /// @return enforced True if a fresh reference was found and the price checked in-bounds; false if the
    /// oracle had no fresh reference for `key` (no opinion). An out-of-bounds price reverts, never returns.
    function check(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (bool enforced);
}
