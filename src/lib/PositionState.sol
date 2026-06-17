// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {V4PositionManager} from "../abstract/V4PositionManager.sol";

/// @title PositionState
/// @notice View-only valuation of a salt-keyed V4 position: current principal split at the live
/// price + uncollected fees. Reads pool state through `StateLibrary` (`extsload`) — no `unlock`,
/// so it is safe to call from `tokenURI` / off-chain. Kept as a library so the heavy math stays
/// out of the wallet bytecode (EIP-170).
library PositionState {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q128 = 1 << 128;

    /// @param pm    The V4 PoolManager the position lives in.
    /// @param owner The position owner (the wallet/manager address).
    /// @param salt  The registry salt (mapping key); needed to derive the position id.
    /// @param p     The stored position record (`positions[salt]`).
    function value(IPoolManager pm, address owner, bytes32 salt, V4PositionManager.Position memory p)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        if (p.liquidity == 0) return (0, 0, 0, 0);

        PoolId poolId = p.key.toId();
        (uint160 sqrtP,,,) = pm.getSlot0(poolId);
        if (sqrtP == 0) return (0, 0, 0, 0); // uninitialized/odd pool ⇒ degrade gracefully

        (amount0, amount1) = _principal(
            sqrtP, TickMath.getSqrtPriceAtTick(p.tickLower), TickMath.getSqrtPriceAtTick(p.tickUpper), p.liquidity
        );
        (fees0, fees1) = _fees(pm, owner, salt, poolId, p);
    }

    /// @dev Uncollected fees = liquidity * (feeGrowthInside_now - feeGrowthInside_last) / 2**128,
    /// per token. Split out to keep {value}'s stack shallow (no via-IR).
    function _fees(IPoolManager pm, address owner, bytes32 salt, PoolId poolId, V4PositionManager.Position memory p)
        private
        view
        returns (uint256 fees0, uint256 fees1)
    {
        (, uint256 fg0Last, uint256 fg1Last) = pm.getPositionInfo(poolId, owner, p.tickLower, p.tickUpper, salt);
        (uint256 fg0Now, uint256 fg1Now) = pm.getFeeGrowthInside(poolId, p.tickLower, p.tickUpper);
        // feeGrowth accumulators are designed to wrap; the difference is the per-unit fee owed.
        unchecked {
            fees0 = FullMath.mulDiv(fg0Now - fg0Last, p.liquidity, Q128);
            fees1 = FullMath.mulDiv(fg1Now - fg1Last, p.liquidity, Q128);
        }
    }

    /// @dev Principal split of `liquidity` over [sqrtA, sqrtB] at the current price `sqrtP`.
    /// Mirrors v3/v4 `getAmountsForLiquidity` (absent from this repo's trimmed LiquidityAmounts).
    function _principal(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }
}
