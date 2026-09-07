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
    /// @dev `amountIn == 0` is a sentinel: no swap ran, and the implementation is asked to judge the
    /// pool's spot price against the reference instead of a realized price. `zeroForOne` and
    /// `amountOut` are ignored in that mode. A second implementation must honour this or the fixed-range
    /// product's operator adds will pass unjudged.
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

    /// @notice The single entry point a product with operator-chosen ranges uses for every operator
    /// operation. `amountIn > 0` is a swap and is judged exactly as {check} would; `amountIn == 0` is a
    /// liquidity add, and the implementation must vouch both for the pool's spot price and for the
    /// position's midpoint sitting within a (tighter) tolerance of the reference. The second bound is
    /// what stops the parked-range drain (audit 2026-09-04, R-2): an operator's loss per operation is the
    /// distance from the range midpoint to the reference, so bounding that distance bounds the loss —
    /// while a narrow position placed *at* the fair price stays legal.
    /// @dev One method rather than two so a manager has one external call site: each call encodes the
    /// whole `PoolKey`, and the second encoder did not fit the EIP-170 budget. Same tri-state contract
    /// as {check}. `tickLower`/`tickUpper` are ignored for a swap. A product with fixed, owner-chosen
    /// ranges (`StableLPManager`) keeps using {check}, whose `amountIn == 0` mode is the spot half alone.
    /// @param key The pool.
    /// @param zeroForOne Swap direction; ignored for an add.
    /// @param amountIn Realized swap input, or 0 for an add.
    /// @param amountOut Realized swap output; ignored for an add.
    /// @param tickLower The position's lower bound (add only).
    /// @param tickUpper The position's upper bound (add only).
    function checkOp(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (bool enforced);
}
