// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4PositionManager} from "../../src/abstract/V4PositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Minimal concrete subclass of {V4PositionManager} with NO access control,
/// used to exercise the V4 mechanics (position lifecycle + swaps) in isolation from
/// the NFT/operator authorization that lives in the product contracts.
/// Mirrors how a real subclass wires `_poolManager()` and seeds the hookless pool.
contract V4PositionManagerHarness is V4PositionManager {
    IPoolManager private immutable PM;

    /// @dev Demonstrates the swap-then-add netting an allocate-style flow relies on.
    uint8 internal constant SWAP_THEN_ADD = 100;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return PM;
    }

    // ────────── Ungated pass-throughs to the base internals ──────────

    function open(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt,
        uint128 minPoolLiquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) external {
        _openPosition(key, tickLower, tickUpper, liquidity, salt, minPoolLiquidity, amount0Max, amount1Max);
    }

    function close(bytes32 salt) external {
        _closePosition(salt);
    }

    function decrease(bytes32 salt, uint128 deltaLiquidity) external {
        _decreasePosition(salt, deltaLiquidity);
    }

    function poke(bytes32 salt) external {
        _pokePosition(salt);
    }

    // ────────── Swap-then-add (extra op via the extensible dispatcher) ──────────

    struct SwapThenAddParams {
        PoolKey key;
        bool zeroForOne;
        int256 swapAmount; // exactIn ⇒ negative
        uint160 sqrtPriceLimitX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
    }

    /// @notice Swap one currency into the other, then add liquidity, settling only the NET
    /// per-currency delta in a single unlock — the core pattern `StableLPManager.allocate`
    /// will use. Proves the base's `_swap`/`_settle`/`_take` compose without `CurrencyNotSettled`.
    function swapThenAdd(SwapThenAddParams calldata p) external {
        PM.unlock(abi.encode(SWAP_THEN_ADD, abi.encode(p)));
    }

    function _dispatchExtraOp(uint8 op, bytes memory payload) internal override returns (bytes memory) {
        if (op == SWAP_THEN_ADD) return _handleSwapThenAdd(payload);
        return super._dispatchExtraOp(op, payload);
    }

    function _handleSwapThenAdd(bytes memory payload) internal returns (bytes memory) {
        SwapThenAddParams memory p = abi.decode(payload, (SwapThenAddParams));

        BalanceDelta swapDelta = _swap(p.key, p.zeroForOne, p.swapAmount, p.sqrtPriceLimitX96);

        (BalanceDelta addDelta,) = PM.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(p.liquidity)),
                salt: p.salt
            }),
            ""
        );

        int256 net0 = int256(swapDelta.amount0()) + int256(addDelta.amount0());
        int256 net1 = int256(swapDelta.amount1()) + int256(addDelta.amount1());
        _netCurrency(p.key.currency0, net0);
        _netCurrency(p.key.currency1, net1);
        return "";
    }

    function _netCurrency(Currency currency, int256 net) internal {
        if (net < 0) {
            _settle(currency, uint256(-net));
        } else if (net > 0) {
            _take(currency, address(this), uint256(net));
        }
    }
}
