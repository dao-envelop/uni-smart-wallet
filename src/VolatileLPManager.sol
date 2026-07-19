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
        if (op == uint8(Op.POKE)) return _handleClaim(payload); // claimFees (with protocol fee)
        if (op == OP_ALLOCATE_V) return _handleAllocateV(payload);
        if (op == OP_RECENTER) return _handleRecenter(payload);
        return super._dispatchExtraOp(op, payload); // withdraw (op 5) handled by the base
    }

    // ────────── claimFees ──────────

    /// @notice Harvest accrued fees on `salt` to the manager (no principal change); the protocol fee
    /// is skimmed first. Owner-or-operator.
    /// @param salt The position key.
    function claimFees(bytes32 salt) external onlyAuthorized nonReentrant {
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
        _skimFees(r.key, fees);
        _settleCurrency(r.key.currency0);
        _settleCurrency(r.key.currency1);
        emit FeesCollected(r.salt, _pos(fees.amount0()), _pos(fees.amount1()));
        return "";
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
            BalanceDelta sd = _swap(key, leg.zeroForOne, -int256(leg.swapAmountIn), leg.swapPriceLimit);
            int128 inDelta = leg.zeroForOne ? sd.amount0() : sd.amount1();
            // Full-fill guard: a partial fill (swapPriceLimit hit) leaves |inDelta| < requested input.
            if (uint256(uint128(-inDelta)) < leg.swapAmountIn) revert SwapSlippage(leg.poolId);
            int128 outDelta = leg.zeroForOne ? sd.amount1() : sd.amount0();
            if (uint256(uint128(outDelta)) < leg.minAmountOut) revert SwapMinOut(leg.poolId);
            _guardSwap(byOwner, key, leg.zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
        }
        _addLiquidityV(leg, key);
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
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(L)), salt: salt}),
            ""
        );
        _skimFees(key, fees);
    }

    // ────────── recenter ──────────

    /// @notice Move an open position to a new range in one call. Owner-or-operator.
    /// @param p Recenter plan: salt, new range, optional rebalancing swap, and floors/caps.
    function recenter(RecenterParams calldata p) external onlyAuthorized nonReentrant {
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
            _skimFees(key, fees);
        }

        // 2. Optional rebalancing swap toward the new range.
        if (p.swapAmountIn > 0) _rebalanceSwap(key, p, byOwner);

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

    /// @dev The rebalancing swap for recenter: exactIn, partial-fill guard + `minAmountOut` floor, plus
    /// the caller-asymmetric oracle guard (owner: free; operator: oracle-vouched only).
    function _rebalanceSwap(PoolKey memory key, RecenterParams memory p, bool byOwner) internal {
        BalanceDelta sd = _swap(key, p.zeroForOne, -int256(p.swapAmountIn), p.swapPriceLimit);
        int128 inDelta = p.zeroForOne ? sd.amount0() : sd.amount1();
        if (uint256(uint128(-inDelta)) < p.swapAmountIn) revert SwapSlippage(key.toId());
        int128 outDelta = p.zeroForOne ? sd.amount1() : sd.amount0();
        if (uint256(uint128(outDelta)) < p.minAmountOut) revert SwapMinOut(key.toId());
        _guardSwap(byOwner, key, p.zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
    }

    /// @dev The manager's positive credit of `c` in the active unlock (0 if it owes or is flat).
    function _posDelta(Currency c) internal view returns (uint256) {
        int256 d = POOL_MANAGER.currencyDelta(address(this), c);
        return d > 0 ? uint256(d) : 0;
    }
}
