// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PositionMath} from "../lib/PositionMath.sol";

/// @title V4PositionManager
/// @notice Reusable Uniswap V4 interaction layer: concentrated-liquidity position
/// management (open/close/decrease/poke) + swaps, all driven through `PoolManager.unlock`.
/// @dev Auth-agnostic on purpose. Subclasses (`UniSmartWallet`, the upcoming `StableLPManager`,
/// or a test harness) add their own access control and public surface, then call the
/// `internal` action functions here. The PoolManager is resolved through `_poolManager()`
/// so a directly-deployed contract can keep it `immutable` while a clone reads it from storage.
abstract contract V4PositionManager is IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    // ────────── Op codes ──────────

    /// @notice Canonical op codes handled by the base (0–3). Subclasses add their own
    /// `uint8` codes ≥ 4 and route them via `_dispatchExtraOp` (a subclass cannot extend
    /// a base enum). Encoding `Op.OPEN` is ABI-identical to encoding `uint8(0)`.
    enum Op {
        OPEN,
        CLOSE,
        DECREASE,
        POKE
    }

    // ────────── Position state ──────────

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 openedAt;
    }

    mapping(bytes32 => Position) public positions;
    bytes32[] public openSalts;
    /// @dev 1-based index into openSalts so 0 means "not present". Enables O(1) splice.
    mapping(bytes32 => uint256) internal _saltIndexPlusOne;

    // ────────── Events ──────────

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
    event FeesCollected(bytes32 indexed salt, uint256 fees0, uint256 fees1);

    // ────────── Errors ──────────

    error NotPoolManager();
    error UnknownOp(uint8 op);
    error SaltCollision(bytes32 salt);
    error ZeroLiquidity();
    error HookNotAllowed(address hook);
    error PoolUninitialized();
    error PoolLiquidityBelowMin(uint128 actual, uint128 required);
    error ExceedsAmount0Max(uint256 owed, uint128 cap);
    error ExceedsAmount1Max(uint256 owed, uint128 cap);
    error UnknownPosition(bytes32 salt);
    error ZeroDelta();
    error DeltaExceedsLiquidity(uint128 delta, uint128 current);

    // ────────── PoolManager seam ──────────

    /// @dev Resolves the V4 PoolManager. Directly-deployed subclasses override with an
    /// `immutable`; clone-deployed subclasses return a storage var set in `initialize`.
    function _poolManager() internal view virtual returns (IPoolManager);

    // ────────── Unlock callback (extensible dispatcher) ──────────

    /// @notice Called by PoolManager after `unlock(...)`. Handles the canonical ops (0–3)
    /// and forwards anything else to `_dispatchExtraOp` so subclasses can add new ops
    /// (e.g. ALLOCATE / WITHDRAW_TO / REINVEST) without reimplementing the dispatcher.
    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory) {
        if (msg.sender != address(_poolManager())) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == uint8(Op.OPEN)) return _handleOpen(payload);
        if (op == uint8(Op.CLOSE)) return _handleClose(payload);
        if (op == uint8(Op.DECREASE)) return _handleDecrease(payload);
        if (op == uint8(Op.POKE)) return _handlePoke(payload);
        return _dispatchExtraOp(op, payload);
    }

    /// @dev Override to handle subclass-specific op codes (≥ 4). The second arg is the
    /// op payload (unnamed here since the base default ignores it). Default: reject.
    function _dispatchExtraOp(uint8 op, bytes memory) internal virtual returns (bytes memory) {
        revert UnknownOp(op);
    }

    // ────────── Position ops: open ──────────

    struct OpenParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Open a concentrated-liquidity position in `key` at [tickLower, tickUpper].
    /// Validates hook policy + pool existence + minimum pool liquidity, then unlocks PoolManager
    /// to mint liquidity. Settlement comes from this contract's own balance; per-currency owed
    /// amounts must stay under amount0Max / amount1Max (slippage bound).
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

        // Hookless-only policy: a pool with a non-zero hook can break LP economics
        // (e.g. afterRemoveLiquidityReturnDelta skimming the exit), so reject outright.
        if (address(key.hooks) != address(0)) revert HookNotAllowed(address(key.hooks));

        // NB: keep `_poolManager()` calls inline (no local) — this function is already at the
        // stack-depth limit without via-ir; a cached IPoolManager local tips it over.
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = _poolManager().getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolUninitialized();

        if (minPoolLiquidity != 0) {
            uint128 poolLiq = _poolManager().getLiquidity(id);
            if (poolLiq < minPoolLiquidity) revert PoolLiquidityBelowMin(poolLiq, minPoolLiquidity);
        }

        PositionMath.requireValidTickRange(tickLower, tickUpper, key.tickSpacing);

        _unlockOpen(
            OpenParams({
                key: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                salt: salt,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    /// @dev Isolated unlock dispatch for OPEN — kept in its own frame so `_openPosition`
    /// stays under the stack-depth limit (no via-ir).
    function _unlockOpen(OpenParams memory p) private {
        IPoolManager pm = _poolManager();
        pm.unlock(abi.encode(Op.OPEN, abi.encode(p)));
    }

    function _handleOpen(bytes memory payload) internal virtual returns (bytes memory) {
        OpenParams memory p = abi.decode(payload, (OpenParams));

        IPoolManager pm = _poolManager();
        (BalanceDelta delta,) = pm.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(p.liquidity)),
                salt: p.salt
            }),
            ""
        );

        // Adding liquidity → both deltas are <= 0 (we owe). Convert to owed amounts.
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

    // ────────── Position ops: close / decrease / poke ──────────

    struct RemoveParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 deltaLiquidity;
        bytes32 salt;
    }

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

    function _pokePosition(bytes32 salt) internal {
        Position memory p = positions[salt];
        if (p.liquidity == 0) revert UnknownPosition(salt);

        _unlockRemove(Op.POKE, p, 0, salt);
    }

    /// @dev Shared unlock dispatch for close/decrease/poke — they differ only in op code
    /// and the liquidity delta to remove (0 for poke ⇒ fees only).
    function _unlockRemove(Op op, Position memory p, uint128 deltaLiquidity, bytes32 salt) private {
        IPoolManager pm = _poolManager();
        pm.unlock(
            abi.encode(
                op,
                abi.encode(
                    RemoveParams({
                        key: p.key,
                        tickLower: p.tickLower,
                        tickUpper: p.tickUpper,
                        deltaLiquidity: deltaLiquidity,
                        salt: salt
                    })
                )
            )
        );
    }

    function _handleClose(bytes memory payload) internal virtual returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (uint256 owed0, uint256 owed1, uint256 fees0, uint256 fees1) = _withdrawLiquidity(r);

        // Full close: clear registry entry.
        _removeSalt(r.salt);
        delete positions[r.salt];

        emit PositionClosed(r.salt, owed0 - fees0, owed1 - fees1, fees0, fees1);
        return "";
    }

    function _handleDecrease(bytes memory payload) internal virtual returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (uint256 owed0, uint256 owed1, uint256 fees0, uint256 fees1) = _withdrawLiquidity(r);

        positions[r.salt].liquidity -= r.deltaLiquidity;
        // We don't auto-close here even if liquidity hits 0 — the operator can call
        // closePosition explicitly if they want the registry entry cleared.

        emit PositionDecreased(r.salt, r.deltaLiquidity, owed0 - fees0, owed1 - fees1, fees0, fees1);
        return "";
    }

    function _handlePoke(bytes memory payload) internal virtual returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        // deltaLiquidity == 0 in payload — modifyLiquidity(0) releases the fees-owed delta only.
        (uint256 owed0, uint256 owed1,,) = _withdrawLiquidity(r);

        emit FeesCollected(r.salt, owed0, owed1);
        return "";
    }

    /// @dev Shared body for close/decrease/poke: call modifyLiquidity(-deltaLiquidity),
    /// take both currencies to this contract, return (owed0, owed1, fees0, fees1).
    function _withdrawLiquidity(RemoveParams memory r)
        internal
        returns (uint256 owed0, uint256 owed1, uint256 fees0, uint256 fees1)
    {
        IPoolManager pm = _poolManager();
        (BalanceDelta delta, BalanceDelta feesAccrued) = pm.modifyLiquidity(
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

    /// @dev Register a new salt in the open-position index (push + 1-based index).
    /// Shared by `_handleOpen` and subclass flows (e.g. allocate) so the O(1) registry
    /// bookkeeping lives in one place.
    function _registerSalt(bytes32 salt) internal {
        openSalts.push(salt);
        _saltIndexPlusOne[salt] = openSalts.length;
    }

    /// @dev O(1) swap-and-pop removal from openSalts using _saltIndexPlusOne.
    function _removeSalt(bytes32 salt) internal {
        uint256 idxPlusOne = _saltIndexPlusOne[salt];
        if (idxPlusOne == 0) return; // defensive — shouldn't happen if positions[salt] was set
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = openSalts.length - 1;
        if (idx != lastIdx) {
            bytes32 lastSalt = openSalts[lastIdx];
            openSalts[idx] = lastSalt;
            _saltIndexPlusOne[lastSalt] = idx + 1;
        }
        openSalts.pop();
        delete _saltIndexPlusOne[salt];
    }

    // ────────── Swap + settlement primitives ──────────

    /// @dev Swap inside an unlock. Returns the caller's BalanceDelta (negative = owed input,
    /// positive = credited output) WITHOUT settling/taking, so callers can net it against
    /// other operations in the same unlock (e.g. swap-then-add in allocate, or pull-then-swap
    /// in an indirect withdraw). Settlement is the caller's responsibility via `_settle`/`_take`.
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        delta = _poolManager().swap(key, params, "");
    }

    /// @dev Pay an owed currency to the PoolManager from this contract's balance.
    function _settle(Currency currency, uint256 amount) internal {
        currency.settle(_poolManager(), address(this), amount, false);
    }

    /// @dev Withdraw a credited currency from the PoolManager to `recipient`. The
    /// arbitrary-recipient form is the v4-native primitive for delivering funds to an
    /// address without routing them through this contract's ERC-20 balance.
    function _take(Currency currency, address recipient, uint256 amount) internal {
        currency.take(_poolManager(), recipient, amount, false);
    }

    // ────────── Views ──────────

    function positionOf(bytes32 salt) external view returns (Position memory) {
        return positions[salt];
    }

    function openPositionCount() external view returns (uint256) {
        return openSalts.length;
    }
}
