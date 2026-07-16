// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionMath} from "./lib/PositionMath.sol";
import {BaseLPManager} from "./BaseLPManager.sol";

/// @title VolatileLPManager
/// @notice {BaseLPManager} product for arbitrary (volatile) asset pairs. Reuses the base clone/init,
/// managed-currency union, protocol-fee skim, and settlement primitives, and adds what volatile pairs
/// need over the stable model: **per-call tick ranges** and **salt-keyed multi-position** (several
/// ranges per pool), **`amount*Max`** slippage caps on the add (owed is price-sensitive once a range
/// can go one-sided) and **`minAmountOut`** on the balancing pre-swap. `recenter` (single-call
/// remove→swap→re-add) and an external price-oracle guard land in later steps. Ops route via
/// `_dispatchExtraOp` (codes ≥ 7) so the base dispatcher is reused unchanged.
contract VolatileLPManager is BaseLPManager {
    using StateLibrary for IPoolManager;

    // Volatile op codes extend the base set (POKE + StableLP's 4–6); ≥ 7 here.
    uint8 internal constant OP_ALLOCATE_V = 7;
    uint8 internal constant OP_RECENTER = 8;

    /// @notice One volatile allocation: pick a configured pool + a caller-chosen `salt`, a per-call
    /// range, an optional balancing pre-swap (bounded by `minAmountOut`), and an add sized from
    /// desired amounts with `amount{0,1}Max` slippage caps. A pool can hold many salts/ranges at once.
    struct VolatileAllocLeg {
        PoolId poolId; // which configured pool (key comes from `pools`)
        bytes32 salt; // caller-chosen position key (fresh ⇒ new range; existing ⇒ top-up same range)
        int24 tickLower; // per-call range
        int24 tickUpper;
        bool zeroForOne; // pre-swap direction (input side); skip when swapAmountIn == 0
        uint256 swapAmountIn; // exactIn into the pool; 0 = no pre-swap
        uint160 swapPriceLimit; // sqrtPriceLimitX96 — price bound on the pre-swap
        uint256 minAmountOut; // floor on the pre-swap output (slippage on the swap)
        uint256 amount0Desired; // add amounts (bound the spend; L is sized from these at the live price)
        uint256 amount1Desired;
        uint128 minLiquidity; // floor on minted L (slippage on the add)
        uint128 amount0Max; // slippage cap on currency0 owed by the add
        uint128 amount1Max; // slippage cap on currency1 owed by the add
    }

    /// @notice The pre-swap delivered less than `minAmountOut` of the output currency.
    error SwapMinOut(PoolId poolId);
    /// @notice A top-up targeted an existing `salt` with a different range than it was opened at.
    error RangeMismatch(bytes32 salt);

    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) BaseLPManager(poolManager_, treasury_) {}

    // ────────── Product identity ──────────

    /// @inheritdoc BaseLPManager
    function ORACLE_TYPE() public pure override returns (uint256) {
        return 3001;
    }

    /// @notice The NFT symbol — the shared constant `"eVolLP"` for every clone.
    function symbol() public pure override returns (string memory) {
        return "eVolLP";
    }

    function _productName() internal pure override returns (string memory) {
        return "VolatileLPManager";
    }

    function _defaultName() internal pure override returns (bytes32) {
        return bytes32("Envelop Volatile LP Manager");
    }

    // ────────── Unlock dispatch (this product's ops) ──────────

    function _dispatchExtraOp(uint8 op, bytes memory payload) internal override returns (bytes memory) {
        if (op == OP_ALLOCATE_V) return _handleAllocateV(payload);
        return super._dispatchExtraOp(op, payload);
    }

    // ────────── allocate ──────────

    /// @notice Deploy liquidity per `legs` across configured pools with per-call ranges + salts.
    /// Owner-or-operator (off-chain sizing). Draws from whatever managed currencies sit on the
    /// manager's balance; residuals net back via `_settleManaged`.
    /// @param legs Per-position actions (pool, salt, range, optional pre-swap, desired amounts, caps).
    function allocate(VolatileAllocLeg[] calldata legs) external onlyAuthorized nonReentrant {
        if (legs.length == 0) revert NoLegs();
        for (uint256 i = 0; i < legs.length; ++i) {
            _indexOf(legs[i].poolId); // reverts UnknownPool if not configured
        }
        POOL_MANAGER.unlock(abi.encode(OP_ALLOCATE_V, abi.encode(legs)));
        emit Allocated(legs.length);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleAllocateV(bytes memory payload) internal returns (bytes memory) {
        VolatileAllocLeg[] memory legs = abi.decode(payload, (VolatileAllocLeg[]));
        for (uint256 i = 0; i < legs.length; ++i) {
            _allocateLegV(legs[i]);
        }
        _settleManaged();
        return "";
    }

    /// @dev Per-leg: optional exactIn pre-swap (bounded by minAmountOut) to balance the sides, then
    /// add at the caller's range with the `amount*Max` caps. Settlement is deferred to `_settleManaged`.
    function _allocateLegV(VolatileAllocLeg memory leg) internal {
        PoolKey memory key = pools[_indexOf(leg.poolId)].key;
        if (leg.swapAmountIn > 0) {
            BalanceDelta sd = _swap(key, leg.zeroForOne, -int256(leg.swapAmountIn), leg.swapPriceLimit);
            int128 inDelta = leg.zeroForOne ? sd.amount0() : sd.amount1();
            // exactIn: a partial fill (price limit hit) leaves |inDelta| < requested input.
            if (uint256(uint128(-inDelta)) < leg.swapAmountIn) revert SwapSlippage(leg.poolId);
            int128 outDelta = leg.zeroForOne ? sd.amount1() : sd.amount0();
            if (uint256(uint128(outDelta)) < leg.minAmountOut) revert SwapMinOut(leg.poolId);
        }
        _addLiquidityV(leg, key);
    }

    /// @dev Size L from desired amounts at the live price, add at the caller's range under `salt`,
    /// enforce the `amount*Max` owed caps, skim the protocol fee, and record/merge the position. A
    /// fresh salt opens a new range; an existing salt must top up the SAME range.
    function _addLiquidityV(VolatileAllocLeg memory leg, PoolKey memory key) internal returns (uint128 L) {
        PositionMath.requireValidTickRange(leg.tickLower, leg.tickUpper, key.tickSpacing);
        PoolId id = key.toId();
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(id);
        if (sqrtP == 0) revert PoolUninitialized();

        L = PositionMath.liquidityFromAmounts(
            sqrtP, leg.tickLower, leg.tickUpper, leg.amount0Desired, leg.amount1Desired
        );
        if (L < leg.minLiquidity) revert MinLiquidityNotMet(L, leg.minLiquidity);

        (BalanceDelta delta, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: leg.tickLower, tickUpper: leg.tickUpper, liquidityDelta: int256(uint256(L)), salt: leg.salt
            }),
            ""
        );

        // Adding liquidity → owed is the negative caller delta; cap it (volatile ranges go one-sided).
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        uint256 owed0 = d0 < 0 ? uint256(uint128(-d0)) : 0;
        uint256 owed1 = d1 < 0 ? uint256(uint128(-d1)) : 0;
        if (owed0 > leg.amount0Max) revert ExceedsAmount0Max(owed0, leg.amount0Max);
        if (owed1 > leg.amount1Max) revert ExceedsAmount1Max(owed1, leg.amount1Max);

        _skimFees(key, fees); // protocol fee on any accrued fees realized by a top-up

        Position memory ex = positions[leg.salt];
        if (ex.liquidity == 0) {
            positions[leg.salt] = Position({
                key: key,
                tickLower: leg.tickLower,
                tickUpper: leg.tickUpper,
                liquidity: L,
                openedAt: uint64(block.timestamp)
            });
            _registerSalt(leg.salt);
        } else {
            // A salt maps to one V4 position (owner, ticks, salt) — a top-up must reuse its range.
            if (ex.tickLower != leg.tickLower || ex.tickUpper != leg.tickUpper) revert RangeMismatch(leg.salt);
            positions[leg.salt].liquidity += L;
        }
    }
}
