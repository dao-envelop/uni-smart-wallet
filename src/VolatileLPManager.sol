// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PositionMath} from "./lib/PositionMath.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
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
    using TransientStateLibrary for IPoolManager;

    // Volatile op codes extend the base set (POKE + StableLP's 4–6); ≥ 7 here.
    uint8 internal constant OP_ALLOCATE_V = 7;
    uint8 internal constant OP_RECENTER = 8;
    uint8 internal constant OP_WITHDRAW_TO_V = 9;

    /// @notice Optional external price guard for on-chain swaps (allocate pre-swap / recenter
    /// rebalance). Zero ⇒ no oracle: the operator's `amount*Max` / `minAmountOut` are the only guard.
    /// Owner-settable via {setPriceOracle}.
    address public priceOracle;

    /// @notice Emitted when the price oracle is (re)set.
    event PriceOracleSet(address indexed oracle);

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

    /// @notice Move an existing position to a new range in one call: pull all its liquidity, optionally
    /// swap to rebalance the freed sides, then re-add at `[newTickLower, newTickUpper]` under the same
    /// salt. Sized from the freed amounts (like reinvest), so no fresh deposit is needed.
    struct RecenterParams {
        bytes32 salt; // the open position to move
        int24 newTickLower; // destination range
        int24 newTickUpper;
        bool zeroForOne; // rebalancing swap direction; skip when swapAmountIn == 0
        uint256 swapAmountIn; // exactIn for the rebalancing swap
        uint160 swapPriceLimit; // sqrtPriceLimitX96 — price bound on the swap
        uint256 minAmountOut; // floor on the rebalancing swap output
        uint128 minLiquidity; // floor on the re-added L
        uint128 amount0Max; // slippage cap on currency0 owed by the re-add
        uint128 amount1Max; // slippage cap on currency1 owed by the re-add
    }

    /// @notice A single position (by salt) to pull liquidity from during `withdrawTo`.
    struct VWithdrawStep {
        bytes32 salt; // the open position to pull from
        uint128 liquidityToPull; // modifyLiquidity(-L) on it
    }

    /// @notice Convert a freed leg into the requested currency during `withdrawTo` (exactOut preferred).
    struct VWithdrawSwap {
        PoolId poolId; // configured pool to swap in (key from `pools`)
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Deliver `amount` of `requestedCurrency` straight to `recipient` via the v4-native
    /// `take`, without it landing on the manager's or owner's ERC-20 balance. Pull the named positions
    /// (by salt), convert freed legs via `swaps`, then take the requested amount to `recipient`.
    struct VWithdrawToParams {
        address recipient;
        Currency requestedCurrency;
        uint256 amount;
        VWithdrawStep[] pulls;
        VWithdrawSwap[] swaps;
    }

    /// @notice The pre-swap delivered less than `minAmountOut` of the output currency.
    error SwapMinOut(PoolId poolId);
    /// @notice A top-up targeted an existing `salt` with a different range than it was opened at.
    error RangeMismatch(bytes32 salt);

    /// @notice Emitted when a position is moved to a new range.
    /// @param salt The position key.
    /// @param newTickLower The destination lower tick.
    /// @param newTickUpper The destination upper tick.
    /// @param liquidity Liquidity re-added at the new range.
    event Recentered(bytes32 indexed salt, int24 newTickLower, int24 newTickUpper, uint128 liquidity);

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

    // ────────── Price oracle config ──────────

    /// @notice Set (or clear, with the zero address) the external price guard. Owner-only.
    /// @param oracle The {IPriceOracle} to enforce on swaps; zero ⇒ disabled.
    function setPriceOracle(address oracle) external onlyOwnerNFT {
        priceOracle = oracle;
        emit PriceOracleSet(oracle);
    }

    /// @dev Enforce the oracle bound on a just-executed swap (no-op when unset). The oracle reverts if
    /// the realized price is out of bounds; a stale/absent reference is a no-op ⇒ amountMax/minOut hold.
    function _guardSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 amountOut) internal view {
        address o = priceOracle;
        if (o != address(0)) IPriceOracle(o).check(key, zeroForOne, amountIn, amountOut);
    }

    // ────────── Unlock dispatch (this product's ops) ──────────

    function _dispatchExtraOp(uint8 op, bytes memory payload) internal override returns (bytes memory) {
        if (op == uint8(Op.POKE)) return _handleClaim(payload); // claimFees (with protocol fee)
        if (op == OP_ALLOCATE_V) return _handleAllocateV(payload);
        if (op == OP_RECENTER) return _handleRecenter(payload);
        if (op == OP_WITHDRAW_TO_V) return _handleWithdrawToV(payload);
        return super._dispatchExtraOp(op, payload);
    }

    // ────────── claimFees ──────────

    /// @notice Harvest accrued fees on `salt` to the manager (no principal change); the protocol fee
    /// is skimmed first. Owner-or-operator.
    /// @param salt The position key.
    function claimFees(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokePosition(salt); // reverts UnknownPosition if not open
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @dev POKE handler: realize fees (liquidityDelta 0), skim the protocol cut, net the rest back.
    function _handleClaim(bytes memory payload) internal returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            r.key,
            ModifyLiquidityParams({tickLower: r.tickLower, tickUpper: r.tickUpper, liquidityDelta: 0, salt: r.salt}),
            ""
        );
        _skimFees(r.key, fees);
        _settleCurrency(r.key.currency0);
        _settleCurrency(r.key.currency1);
        emit FeesCollected(r.salt, _pos(fees.amount0()), _pos(fees.amount1()));
        return "";
    }

    // ────────── withdrawTo (indirect drain) ──────────

    /// @notice Deliver `p.amount` of `p.requestedCurrency` straight to `p.recipient` via the v4-native
    /// `take` (never landing on the manager/owner balance): pull the named positions by salt, convert
    /// freed legs via `p.swaps`, then take the requested amount. Owner-only — the drain primitive.
    /// @param p Withdraw plan: recipient, requested currency + amount, salt-keyed pulls, conversion swaps.
    function withdrawTo(VWithdrawToParams calldata p) external onlyOwnerNFT nonReentrant {
        if (p.recipient == address(0)) revert RecipientZero();
        if (!isManagedStable[p.requestedCurrency]) revert UnmanagedStable(p.requestedCurrency);
        if (p.amount == 0) revert ZeroAmount();
        for (uint256 i = 0; i < p.pulls.length; ++i) {
            uint128 have = positions[p.pulls[i].salt].liquidity;
            if (have == 0) revert UnknownPosition(p.pulls[i].salt);
            if (p.pulls[i].liquidityToPull > have) revert DeltaExceedsLiquidity(p.pulls[i].liquidityToPull, have);
        }
        POOL_MANAGER.unlock(abi.encode(OP_WITHDRAW_TO_V, abi.encode(p)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleWithdrawToV(bytes memory payload) internal returns (bytes memory) {
        VWithdrawToParams memory p = abi.decode(payload, (VWithdrawToParams));

        for (uint256 i = 0; i < p.pulls.length; ++i) {
            _pullLiquidityV(p.pulls[i].salt, p.pulls[i].liquidityToPull);
        }
        for (uint256 i = 0; i < p.swaps.length; ++i) {
            VWithdrawSwap memory w = p.swaps[i];
            _swap(pools[_indexOf(w.poolId)].key, w.zeroForOne, w.amountSpecified, w.sqrtPriceLimitX96);
        }

        int256 got = POOL_MANAGER.currencyDelta(address(this), p.requestedCurrency);
        if (got < int256(p.amount)) revert AmountNotDelivered(got > 0 ? uint256(got) : 0, p.amount);

        _take(p.requestedCurrency, p.recipient, p.amount);
        _settleManaged();
        emit WithdrawnTo(p.recipient, p.requestedCurrency, p.amount);
        return "";
    }

    /// @dev Pull `liq` from the position keyed `salt` (at its stored range), skim fees, decrement or
    /// remove the registry entry.
    function _pullLiquidityV(bytes32 salt, uint128 liq) internal {
        if (liq == 0) return;
        Position memory pos = positions[salt];
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            pos.key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: -int256(uint256(liq)), salt: salt
            }),
            ""
        );
        _skimFees(pos.key, fees);
        positions[salt].liquidity -= liq;
        if (positions[salt].liquidity == 0) {
            _removeSalt(salt);
            delete positions[salt];
        }
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
            _guardSwap(key, leg.zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
        }
        _addLiquidityV(leg, key);
    }

    /// @dev Size L from desired amounts at the live price, add at the caller's range under `salt`,
    /// enforce the `amount*Max` owed caps, skim the protocol fee, and record/merge the position. A
    /// fresh salt opens a new range; an existing salt must top up the SAME range.
    function _addLiquidityV(VolatileAllocLeg memory leg, PoolKey memory key) internal {
        uint128 L = _addLiquidityAt(
            key,
            leg.tickLower,
            leg.tickUpper,
            leg.salt,
            leg.amount0Desired,
            leg.amount1Desired,
            leg.minLiquidity,
            leg.amount0Max,
            leg.amount1Max
        );
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

    /// @dev Size L from desired amounts at the live price, add under `salt` at [tl,tu], skim the
    /// protocol fee, and enforce the owed `amount*Max` caps. Registry bookkeeping is the caller's job.
    /// Shared by allocate and recenter (kept in its own frame — the stack is tight without via-ir).
    function _addLiquidityAt(
        PoolKey memory key,
        int24 tl,
        int24 tu,
        bytes32 salt,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiq,
        uint128 amt0Max,
        uint128 amt1Max
    ) internal returns (uint128 L) {
        PositionMath.requireValidTickRange(tl, tu, key.tickSpacing);
        {
            (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
            if (sqrtP == 0) revert PoolUninitialized();
            L = PositionMath.liquidityFromAmounts(sqrtP, tl, tu, amount0, amount1);
        }
        if (L < minLiq) revert MinLiquidityNotMet(L, minLiq);
        (BalanceDelta delta, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(L)), salt: salt}),
            ""
        );
        _skimFees(key, fees);
        _checkOwed(delta, amt0Max, amt1Max);
    }

    /// @dev Revert if the add's owed (negative caller delta) exceeds either slippage cap.
    function _checkOwed(BalanceDelta delta, uint128 amt0Max, uint128 amt1Max) internal pure {
        int128 d0 = delta.amount0();
        if (d0 < 0 && uint256(uint128(-d0)) > amt0Max) revert ExceedsAmount0Max(uint256(uint128(-d0)), amt0Max);
        int128 d1 = delta.amount1();
        if (d1 < 0 && uint256(uint128(-d1)) > amt1Max) revert ExceedsAmount1Max(uint256(uint128(-d1)), amt1Max);
    }

    // ────────── recenter ──────────

    /// @notice Move an open position to a new range in one call. Owner-or-operator.
    /// @param p Recenter plan: salt, new range, optional rebalancing swap, and floors/caps.
    function recenter(RecenterParams calldata p) external onlyAuthorized nonReentrant {
        if (positions[p.salt].liquidity == 0) revert UnknownPosition(p.salt);
        POOL_MANAGER.unlock(abi.encode(OP_RECENTER, abi.encode(p)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleRecenter(bytes memory payload) internal returns (bytes memory) {
        RecenterParams memory p = abi.decode(payload, (RecenterParams));
        Position memory pos = positions[p.salt];
        PoolKey memory key = pos.key;

        // 1. Pull the whole position at its old range — principal + fees become positive deltas.
        {
            (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: pos.tickLower,
                    tickUpper: pos.tickUpper,
                    liquidityDelta: -int256(uint256(pos.liquidity)),
                    salt: p.salt
                }),
                ""
            );
            _skimFees(key, fees);
        }

        // 2. Optional rebalancing swap toward the new range.
        if (p.swapAmountIn > 0) _rebalanceSwap(key, p);

        // 3. Re-add at the new range, sized from the freed (positive) deltas.
        uint128 L = _addLiquidityAt(
            key,
            p.newTickLower,
            p.newTickUpper,
            p.salt,
            _posDelta(key.currency0),
            _posDelta(key.currency1),
            p.minLiquidity,
            p.amount0Max,
            p.amount1Max
        );

        // 4. Repoint the registry entry to the new range/liquidity (same salt, keep openedAt).
        positions[p.salt] = Position({
            key: key, tickLower: p.newTickLower, tickUpper: p.newTickUpper, liquidity: L, openedAt: pos.openedAt
        });

        _settleManaged(); // net residuals back to the manager
        emit Recentered(p.salt, p.newTickLower, p.newTickUpper, L);
        return "";
    }

    /// @dev The rebalancing swap for recenter: exactIn, partial-fill guard + `minAmountOut` floor.
    function _rebalanceSwap(PoolKey memory key, RecenterParams memory p) internal {
        BalanceDelta sd = _swap(key, p.zeroForOne, -int256(p.swapAmountIn), p.swapPriceLimit);
        int128 inDelta = p.zeroForOne ? sd.amount0() : sd.amount1();
        if (uint256(uint128(-inDelta)) < p.swapAmountIn) revert SwapSlippage(key.toId());
        int128 outDelta = p.zeroForOne ? sd.amount1() : sd.amount0();
        if (uint256(uint128(outDelta)) < p.minAmountOut) revert SwapMinOut(key.toId());
        _guardSwap(key, p.zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
    }

    /// @dev The manager's positive credit of `c` in the active unlock (0 if it owes or is flat).
    function _posDelta(Currency c) internal view returns (uint256) {
        int256 d = POOL_MANAGER.currencyDelta(address(this), c);
        return d > 0 ? uint256(d) : 0;
    }
}
