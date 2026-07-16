// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4PositionManager} from "../../src/abstract/V4PositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionMath} from "../../src/lib/PositionMath.sol";

/// @notice Test-only mixin that restores the standalone explicit-liquidity position lifecycle
/// (open / close / decrease + the fees-only poke handler) on top of {V4PositionManager}. These ops
/// were removed from the production base when UniSmartWallet was retired — no product contract uses
/// them — so they live here purely to drive the descriptor / lens / PositionState / base-mechanics
/// test suites. Routed through an `unlockCallback` override; unknown ops fall through to
/// `_dispatchExtraOp` so concrete harnesses can still add their own ops.
abstract contract V4PositionOpsHarness is V4PositionManager {
    using StateLibrary for IPoolManager;

    struct OpenParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    event PositionOpened(
        bytes32 indexed salt,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Used,
        uint256 amount1Used
    );
    event PositionClosed(bytes32 indexed salt, uint256 principal0, uint256 principal1, uint256 fees0, uint256 fees1);
    event PositionDecreased(
        bytes32 indexed salt,
        uint128 deltaLiquidity,
        uint256 principal0,
        uint256 principal1,
        uint256 fees0,
        uint256 fees1
    );

    constructor(IPoolManager poolManager_) V4PositionManager(poolManager_) {}

    /// @dev Route the canonical ops (0–3) to the local handlers; everything else to the subclass.
    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == uint8(Op.OPEN)) return _handleOpen(payload);
        if (op == uint8(Op.CLOSE)) return _handleClose(payload);
        if (op == uint8(Op.DECREASE)) return _handleDecrease(payload);
        if (op == uint8(Op.POKE)) return _handlePoke(payload);
        return _dispatchExtraOp(op, payload);
    }

    // ────────── open ──────────

    function _openPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt,
        uint128 minPoolLiquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal {
        if (positions[salt].liquidity != 0) revert SaltCollision(salt);
        if (liquidity == 0) revert ZeroLiquidity();
        if (address(key.hooks) != address(0)) revert HookNotAllowed(address(key.hooks));

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolUninitialized();

        if (minPoolLiquidity != 0) {
            uint128 poolLiq = POOL_MANAGER.getLiquidity(id);
            if (poolLiq < minPoolLiquidity) revert PoolLiquidityBelowMin(poolLiq, minPoolLiquidity);
        }

        PositionMath.requireValidTickRange(tickLower, tickUpper, key.tickSpacing);

        POOL_MANAGER.unlock(
            abi.encode(
                Op.OPEN,
                abi.encode(
                    OpenParams({
                        key: key,
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidity: liquidity,
                        salt: salt,
                        amount0Max: amount0Max,
                        amount1Max: amount1Max
                    })
                )
            )
        );
    }

    function _handleOpen(bytes memory payload) internal returns (bytes memory) {
        OpenParams memory p = abi.decode(payload, (OpenParams));

        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(p.liquidity)),
                salt: p.salt
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 owed0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 owed1 = d1 < 0 ? uint256(uint128(-d1)) : 0;

        if (owed0 > p.amount0Max) revert ExceedsAmount0Max(owed0, p.amount0Max);
        if (owed1 > p.amount1Max) revert ExceedsAmount1Max(owed1, p.amount1Max);

        if (owed0 > 0) _settle(p.key.currency0, owed0);
        if (owed1 > 0) _settle(p.key.currency1, owed1);

        positions[p.salt] = Position({
            key: p.key,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: p.liquidity,
            openedAt: uint64(block.timestamp)
        });
        _registerSalt(p.salt);

        emit PositionOpened(p.salt, p.key.toId(), p.tickLower, p.tickUpper, p.liquidity, owed0, owed1);
        return "";
    }

    // ────────── close / decrease / poke ──────────

    function _closePosition(bytes32 salt) internal {
        Position memory p = positions[salt];
        if (p.liquidity == 0) revert UnknownPosition(salt);
        _unlockRemove(Op.CLOSE, p, p.liquidity, salt);
    }

    function _decreasePosition(bytes32 salt, uint128 deltaLiquidity) internal {
        Position memory p = positions[salt];
        if (p.liquidity == 0) revert UnknownPosition(salt);
        if (deltaLiquidity == 0) revert ZeroDelta();
        if (deltaLiquidity > p.liquidity) revert DeltaExceedsLiquidity(deltaLiquidity, p.liquidity);
        _unlockRemove(Op.DECREASE, p, deltaLiquidity, salt);
    }

    function _handleClose(bytes memory payload) internal returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (uint256 owed0, uint256 owed1, uint256 fees0, uint256 fees1) = _withdrawLiquidity(r);
        _removeSalt(r.salt);
        delete positions[r.salt];
        emit PositionClosed(r.salt, owed0 - fees0, owed1 - fees1, fees0, fees1);
        return "";
    }

    function _handleDecrease(bytes memory payload) internal returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (uint256 owed0, uint256 owed1, uint256 fees0, uint256 fees1) = _withdrawLiquidity(r);
        positions[r.salt].liquidity -= r.deltaLiquidity;
        emit PositionDecreased(r.salt, r.deltaLiquidity, owed0 - fees0, owed1 - fees1, fees0, fees1);
        return "";
    }

    function _handlePoke(bytes memory payload) internal returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (uint256 owed0, uint256 owed1,,) = _withdrawLiquidity(r);
        emit FeesCollected(r.salt, owed0, owed1);
        return "";
    }

    function _withdrawLiquidity(RemoveParams memory r)
        internal
        returns (uint256 owed0, uint256 owed1, uint256 fees0, uint256 fees1)
    {
        (BalanceDelta delta, BalanceDelta feesAccrued) = POOL_MANAGER.modifyLiquidity(
            r.key,
            ModifyLiquidityParams({
                tickLower: r.tickLower,
                tickUpper: r.tickUpper,
                liquidityDelta: -int256(uint256(r.deltaLiquidity)),
                salt: r.salt
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        owed0 = d0 > 0 ? uint256(uint128(d0)) : 0;
        owed1 = d1 > 0 ? uint256(uint128(d1)) : 0;

        int128 f0 = feesAccrued.amount0();
        int128 f1 = feesAccrued.amount1();
        fees0 = f0 > 0 ? uint256(uint128(f0)) : 0;
        fees1 = f1 > 0 ? uint256(uint128(f1)) : 0;

        if (owed0 > 0) _take(r.key.currency0, address(this), owed0);
        if (owed1 > 0) _take(r.key.currency1, address(this), owed1);
    }
}
