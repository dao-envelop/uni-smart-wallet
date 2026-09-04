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
import {BaseLPManager} from "./BaseLPManager.sol";

/// @title VolatileLPManager
/// @notice {BaseLPManager} product for arbitrary (volatile) asset pairs. Reuses the base clone/init,
/// managed-currency union, protocol-fee skim, and settlement primitives, and adds what volatile pairs
/// need over the stable model: **per-call tick ranges** and **salt-keyed multi-position** (several
/// ranges per pool, `salt ≠ poolId` ⇒ the position stores its `poolId`) and **`minAmountOut`** on the
/// balancing pre-swap, plus `recenter` (single-call remove→swap→re-add) and an optional external
/// price-oracle guard. The add is sized from desired amounts with a `minLiquidity` floor (owed ≤
/// desired by construction — no `amount*Max` cap, as in `StableLPManager`). Ops route via
/// `_dispatchExtraOp` (codes ≥ 7) so the base dispatcher is reused unchanged.
contract VolatileLPManager is BaseLPManager {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Volatile op codes extend the base set (0–3 canonical + base OP_WITHDRAW_TO = 5); ≥ 7 here.
    uint8 internal constant OP_ALLOCATE_V = 7;
    uint8 internal constant OP_RECENTER = 8;
    uint8 internal constant OP_MOVE = 9;

    /// @notice Init parameters for a volatile manager clone — pools are keys only (ranges are per-call,
    /// so there is no pool-level range to configure).
    struct InitParams {
        address owner; // receives the singleton NFT
        bytes32 name; // NFT name, packed (≤31 chars); "" ⇒ default "Envelop Volatile LP Manager"
        address descriptor; // default tokenURI renderer; zero ⇒ none (owner sets later)
        PoolKey[] pools; // 1..MAX_POOLS hookless pools (identity only)
    }

    /// @notice One volatile allocation: pick a configured pool + a caller-chosen `salt`, a per-call
    /// range, an optional balancing pre-swap (bounded by `minAmountOut`), and an add sized from desired
    /// amounts. A pool can hold many salts/ranges at once. Slippage on the add is `minLiquidity`: L is
    /// sized from `amount{0,1}Desired` via `getLiquidityForAmounts`, so owed ≤ desired by construction —
    /// no separate `amount*Max` cap is needed (matching `StableLPManager` and v4's own from-amounts add).
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
        uint128 minLiquidity; // floor on the re-added L (slippage on the add; owed ≤ freed by construction)
    }

    /// @notice The pre-swap delivered less than `minAmountOut` of the output currency.
    error SwapMinOut(PoolId poolId);
    /// @notice A top-up targeted an existing `salt` with a different pool or range than it was opened at.
    error RangeMismatch(bytes32 salt);

    /// @notice Emitted when a position is moved to a new range.
    /// @param salt The position key.
    /// @param newTickLower The destination lower tick.
    /// @param newTickUpper The destination upper tick.
    /// @param liquidity Liquidity re-added at the new range.
    event Recentered(bytes32 indexed salt, int24 newTickLower, int24 newTickUpper, uint128 liquidity);

    /// @notice Emitted when liquidity is moved from one position to another, possibly in a different pool.
    /// @param fromSalt The position it was freed from.
    /// @param toSalt The position it was deployed into (may be new or an existing top-up).
    /// @param liquidityPulled Liquidity removed from the source; what arrives at the destination depends
    /// on the destination range and the optional pre-swap, and is in the v4 `ModifyLiquidity` log.
    event LiquidityMoved(bytes32 indexed fromSalt, bytes32 indexed toSalt, uint128 liquidityPulled);

    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) BaseLPManager(poolManager_, treasury_) {}

    /// @notice One-shot initializer, called by the factory on the freshly-cloned proxy: registers the
    /// pools (identity only) + managed currencies, mints the singleton NFT, and reverts if called twice.
    /// @param p Init parameters: owner, packed NFT name (empty ⇒ default), and 1..MAX_POOLS pool keys.
    function initialize(InitParams calldata p) external {
        _beginInit(p.name);
        uint256 n = p.pools.length;
        if (n == 0) revert NoPools();
        if (n > MAX_POOLS) revert TooManyPools(n);
        for (uint256 i = 0; i < n; ++i) {
            _registerPool(p.pools[i]); // hookless gate + dedup + managed-currency union
        }
        _finishInit(p.owner, n, p.descriptor);
    }

    // ────────── Product identity ──────────

    /// @inheritdoc BaseLPManager
    function ORACLE_TYPE() public pure virtual override returns (uint256) {
        return 3001;
    }

    /// @notice The NFT symbol — the shared constant `"eVolLP"` for every clone.
    function symbol() public pure virtual override returns (string memory) {
        return "eVolLP";
    }

    function _productName() internal pure virtual override returns (string memory) {
        return "VolatileLPManager";
    }

    function _defaultName() internal pure virtual override returns (bytes32) {
        return bytes32("Envelop Volatile LP Manager");
    }

    // ────────── Unlock dispatch (this product's ops) ──────────

    function _dispatchExtraOp(uint8 op, bytes memory payload) internal override returns (bytes memory) {
        if (op == uint8(Op.POKE)) return _handleClaim(payload); // claimFees (with protocol fee)
        if (op == OP_ALLOCATE_V) return _handleAllocateV(payload);
        if (op == OP_RECENTER) return _handleRecenter(payload);
        if (op == OP_MOVE) return _handleMove(payload);
        return super._dispatchExtraOp(op, payload); // withdraw (op 5) handled by the base
    }

    // ────────── claimFees ──────────

    /// @notice Harvest accrued fees on `salt` to the manager (no principal change); the protocol fee
    /// is skimmed first. Owner-or-operator.
    /// @param salt The position key.
    function claimFees(bytes32 salt) external onlyAuthorized nonReentrant fixEtherBalance {
        _pokeFromConfig(salt); // reverts UnknownPosition if not open
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
        _skimFees(r.key, r.salt, fees); // emits FeesCollected
        _settleCurrency(r.key.currency0);
        _settleCurrency(r.key.currency1);
        return "";
    }

    // ────────── allocate ──────────

    /// @notice Deploy liquidity per `legs` across configured pools with per-call ranges + salts.
    /// Owner-or-operator (off-chain sizing). Draws from whatever managed currencies sit on the
    /// manager's balance; residuals net back via `_settleManaged`.
    /// @param legs Per-position actions (pool, salt, range, optional pre-swap, desired amounts, caps).
    function allocate(VolatileAllocLeg[] calldata legs) external onlyAuthorized nonReentrant fixEtherBalance {
        if (legs.length == 0) revert NoLegs();
        for (uint256 i = 0; i < legs.length; ++i) {
            _indexOf(legs[i].poolId); // reverts UnknownPool if not configured
        }
        POOL_MANAGER.unlock(abi.encode(OP_ALLOCATE_V, abi.encode(_isOwnerCall(), legs)));
        emit Allocated(legs.length);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleAllocateV(bytes memory payload) internal returns (bytes memory) {
        (bool byOwner, VolatileAllocLeg[] memory legs) = abi.decode(payload, (bool, VolatileAllocLeg[]));
        for (uint256 i = 0; i < legs.length; ++i) {
            _allocateLegV(legs[i], byOwner);
        }
        _settleManaged();
        return "";
    }

    /// @dev Per-leg: optional exactIn pre-swap (bounded by `minAmountOut`) to balance the sides, then
    /// add at the caller's range (sized from desired amounts, floored by `minLiquidity`). Settlement is
    /// deferred to `_settleManaged`. The pre-swap carries the canonical Uniswap pair of guards —
    /// `swapPriceLimit` (marginal-price ceiling) and `minAmountOut` (total-output floor) — plus a
    /// full-fill requirement that enforces "swap exactly `swapAmountIn`" (a partial pre-swap would
    /// under-balance the sides before the add).
    function _allocateLegV(VolatileAllocLeg memory leg, bool byOwner) internal {
        PoolKey memory key = pools[_indexOf(leg.poolId)].key;
        if (leg.swapAmountIn > 0) {
            _guardedSwap(key, leg.zeroForOne, leg.swapAmountIn, leg.swapPriceLimit, leg.minAmountOut, byOwner);
        }
        _addLiquidityV(leg, key);
    }

    /// @dev The product's one swap path: exactIn, with the canonical Uniswap pair of guards —
    /// `priceLimit` (marginal-price ceiling) and `minOut` (total-output floor) — plus a full-fill
    /// requirement, because a partial swap would leave the sides unbalanced for whatever comes next.
    /// On top of those, the caller-asymmetric oracle guard: the owner swaps freely, an operator only
    /// at a price the oracle vouches for. Allocate, recenter and move all route through here.
    function _guardedSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 priceLimit,
        uint256 minOut,
        bool byOwner
    ) internal {
        BalanceDelta sd = _swap(key, zeroForOne, -int256(amountIn), priceLimit);
        int128 inDelta = zeroForOne ? sd.amount0() : sd.amount1();
        // Full-fill guard: a partial fill (priceLimit hit) leaves |inDelta| < requested input.
        if (uint256(uint128(-inDelta)) < amountIn) revert SwapSlippage(key.toId());
        int128 outDelta = zeroForOne ? sd.amount1() : sd.amount0();
        if (uint256(uint128(outDelta)) < minOut) revert SwapMinOut(key.toId());
        _guardSwap(byOwner, key, zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
    }

    /// @dev Size L from desired amounts at the live price, add at the caller's range under `salt`,
    /// skim the protocol fee, and record/merge the position. A fresh salt opens a new range; an
    /// existing salt must top up the SAME pool + range.
    function _addLiquidityV(VolatileAllocLeg memory leg, PoolKey memory key) internal {
        uint128 L = _addLiquidityAt(
            key, leg.tickLower, leg.tickUpper, leg.salt, leg.amount0Desired, leg.amount1Desired, leg.minLiquidity
        );
        StoredPosition memory ex = _positions[leg.salt];
        if (ex.liquidity == 0) {
            _positions[leg.salt] = StoredPosition({
                poolId: leg.poolId,
                tickLower: leg.tickLower,
                tickUpper: leg.tickUpper,
                liquidity: L,
                openedAt: uint64(block.timestamp)
            });
            _registerSalt(leg.salt);
        } else {
            // A salt maps to one V4 position (owner, ticks, salt) — a top-up must reuse its pool + range.
            if (
                PoolId.unwrap(ex.poolId) != PoolId.unwrap(leg.poolId) || ex.tickLower != leg.tickLower
                    || ex.tickUpper != leg.tickUpper
            ) revert RangeMismatch(leg.salt);
            _positions[leg.salt].liquidity += L;
        }
    }

    /// @dev Size L from desired amounts at the live price, add under `salt` at [tl,tu], skim the
    /// protocol fee. `minLiq` is the slippage floor: L is sized from `amount0`/`amount1` via
    /// `getLiquidityForAmounts` (L rounded down), so owed ≤ the desired amounts by construction and no
    /// separate owed-cap is needed. Registry bookkeeping is the caller's job. Shared by allocate and
    /// recenter (kept in its own frame — the stack is tight without via-ir).
    function _addLiquidityAt(
        PoolKey memory key,
        int24 tl,
        int24 tu,
        bytes32 salt,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiq
    ) internal returns (uint128 L) {
        PositionMath.requireValidTickRange(tl, tu, key.tickSpacing);
        {
            (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
            if (sqrtP == 0) revert PoolUninitialized();
            L = PositionMath.liquidityFromAmounts(sqrtP, tl, tu, amount0, amount1);
        }
        if (L < minLiq) revert MinLiquidityNotMet(L, minLiq);
        if (L == 0) revert ZeroLiquidity(); // reject no-op adds (would register a ghost salt)
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(L)), salt: salt}),
            ""
        );
        _skimFees(key, salt, fees);
    }

    // ────────── recenter ──────────

    /// @notice Move an open position to a new range in one call. Owner-or-operator.
    /// @param p Recenter plan: salt, new range, optional rebalancing swap, and floors/caps.
    function recenter(RecenterParams calldata p) external onlyAuthorized nonReentrant fixEtherBalance {
        if (_positions[p.salt].liquidity == 0) revert UnknownPosition(p.salt);
        POOL_MANAGER.unlock(abi.encode(OP_RECENTER, abi.encode(_isOwnerCall(), p)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleRecenter(bytes memory payload) internal returns (bytes memory) {
        (bool byOwner, RecenterParams memory p) = abi.decode(payload, (bool, RecenterParams));
        StoredPosition memory pos = _positions[p.salt];
        PoolKey memory key = pools[_indexOf(pos.poolId)].key;

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
            _skimFees(key, p.salt, fees);
        }

        // 2. Optional rebalancing swap toward the new range.
        if (p.swapAmountIn > 0) {
            _guardedSwap(key, p.zeroForOne, p.swapAmountIn, p.swapPriceLimit, p.minAmountOut, byOwner);
        }

        // 3. Re-add at the new range, sized from the freed (positive) deltas.
        uint128 L = _addLiquidityAt(
            key,
            p.newTickLower,
            p.newTickUpper,
            p.salt,
            _posDelta(key.currency0),
            _posDelta(key.currency1),
            p.minLiquidity
        );

        // 4. Repoint the registry entry to the new range/liquidity (same salt + pool, keep openedAt).
        _positions[p.salt] = StoredPosition({
            poolId: pos.poolId,
            tickLower: p.newTickLower,
            tickUpper: p.newTickUpper,
            liquidity: L,
            openedAt: pos.openedAt
        });

        _settleManaged(); // net residuals back to the manager
        emit Recentered(p.salt, p.newTickLower, p.newTickUpper, L);
        return "";
    }

    // ────────── moveLiquidity ──────────

    /// @notice Move liquidity from one or more pools into others in a single unlock. Owner-or-operator.
    ///
    /// `recenter` already does free → swap → re-add atomically, but only inside one pool. This lifts that
    /// restriction: v4 keys deltas by (address, currency) rather than by pool, and `unlock` checks exactly
    /// one thing on exit — that no non-zero delta remains — so touching several pools in one callback is
    /// legal. Doing so saves the second transaction's intrinsic gas and its extra settlement pass, and
    /// removes the window in which the capital sits idle between closing one position and opening another.
    ///
    /// What this deliberately does NOT promise: the operator picks the destination range and may leave
    /// part of the freed capital idle instead of re-deploying it. That is degradation of yield, not theft —
    /// nothing leaves the manager. The operation widens the operator's radius (`recenter` moves within one
    /// pool, this moves between pools of the owner-fixed set), not the class of things it may do.
    ///
    /// One source, one destination. The array form (many pulls, many adds) does not fit the EIP-170
    /// budget: arrays of structs need their own calldata-to-memory encoder and memory decoder, and the
    /// pair costs more than the manager has left. Moving one position is also the case that exists —
    /// an operator repeats the call to move several.
    /// @param fromSalt The open position to free.
    /// @param liquidity How much of it to pull; the whole amount closes the position.
    /// @param add Where the proceeds go — an ordinary allocate leg, with its own pool, range, optional
    /// pre-swap and floors. May be a fresh salt or a top-up of an existing position.
    function moveLiquidity(bytes32 fromSalt, uint128 liquidity, VolatileAllocLeg calldata add)
        external
        onlyAuthorized
        nonReentrant
        fixEtherBalance
    {
        // `_pullLiquidity` returns silently on a zero pull, which would turn this into a plain allocate
        // funded from whatever happens to sit on the balance. Reject it here, where the revert is clear.
        if (liquidity == 0) revert ZeroLiquidity();
        POOL_MANAGER.unlock(abi.encode(OP_MOVE, abi.encode(_isOwnerCall(), fromSalt, liquidity, add)));
        emit LiquidityMoved(fromSalt, add.salt, liquidity);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @dev Free, then re-deploy, then settle once. Both halves reuse the paths the product already has:
    /// `_pullLiquidity` (fee skim, registry decrement, close-on-zero, realized-fee event) and
    /// `_allocateLegV` (pre-swap with its full-fill and `minAmountOut` guards, the oracle check for
    /// operators, and the add with its `minLiquidity` floor). The single `_settleManaged` at the end is
    /// what makes this cheaper than two transactions: settlement walks the managed currency union once,
    /// no matter how many pools were touched.
    function _handleMove(bytes memory payload) internal returns (bytes memory) {
        (bool byOwner, bytes32 fromSalt, uint128 liquidity, VolatileAllocLeg memory add) =
            abi.decode(payload, (bool, bytes32, uint128, VolatileAllocLeg));
        _pullLiquidity(fromSalt, liquidity);
        _allocateLegV(add, byOwner);
        _settleManaged();
        return "";
    }

    /// @dev The manager's positive credit of `c` in the active unlock (0 if it owes or is flat).
    function _posDelta(Currency c) internal view returns (uint256) {
        int256 d = POOL_MANAGER.currencyDelta(address(this), c);
        return d > 0 ? uint256(d) : 0;
    }
}
