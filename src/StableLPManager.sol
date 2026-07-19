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

/// @title StableLPManager
/// @notice The stable-pool LP manager: a {BaseLPManager} product for a configured set of hookless
/// stable pools (arbitrary pairs, no common quote). Positions are keyed `salt == poolId` (one per
/// pool) with fixed ranges set at `initialize`; operator-driven allocation carries no `amount*Max`
/// cap (owed ≤ desired at the on-chain price, guarded by `minLiquidity`), plus the indirect
/// `withdrawTo` drain. The stable ops (allocate/withdrawTo/reinvest/claimFees) live here; the shared
/// clone/init/managed-set/protocol-fee/settlement/metadata core lives in {BaseLPManager}.
contract StableLPManager is BaseLPManager {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Op codes extending the base set (0–3 canonical + base OP_WITHDRAW_TO = 5, see BaseLPManager).
    uint8 internal constant OP_ALLOCATE = 4;
    uint8 internal constant OP_REINVEST = 6;

    /// @notice The fixed per-pool range (a stable-product policy). One position per pool at this range.
    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice A pool + its fixed range, as supplied at `initialize`.
    struct StablePoolInit {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Init parameters for a stable manager clone.
    struct InitParams {
        address owner; // receives the singleton NFT
        bytes32 name; // NFT name, packed (≤31 chars); "" ⇒ default "Envelop LP Uniswap Manager"
        address descriptor; // default tokenURI renderer; zero ⇒ none (owner sets later)
        StablePoolInit[] pools; // 1..MAX_POOLS hookless stable pools + their fixed ranges
    }

    /// @notice The configured range per pool (`poolId → range`), set once at `initialize`.
    mapping(PoolId => Range) internal _range;

    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) BaseLPManager(poolManager_, treasury_) {}

    /// @notice One-shot initializer, called by the factory on the freshly-cloned proxy: registers the
    /// pools + their fixed ranges + managed stables, mints the singleton NFT, and reverts if called twice.
    /// @param p Init parameters: owner, packed NFT name (empty ⇒ default), and 1..MAX_POOLS pools+ranges.
    function initialize(InitParams calldata p) external {
        _beginInit(p.name);
        uint256 n = p.pools.length;
        if (n == 0) revert NoPools();
        if (n > MAX_POOLS) revert TooManyPools(n);
        for (uint256 i = 0; i < n; ++i) {
            StablePoolInit calldata c = p.pools[i];
            PositionMath.requireValidTickRange(c.tickLower, c.tickUpper, c.key.tickSpacing);
            _registerPool(c.key); // hookless gate + dedup + managed-currency union
            _range[c.key.toId()] = Range({tickLower: c.tickLower, tickUpper: c.tickUpper});
        }
        _finishInit(p.owner, n, p.descriptor);
    }

    // ────────── Product identity ──────────

    /// @inheritdoc BaseLPManager
    function ORACLE_TYPE() public pure override returns (uint256) {
        return 3000;
    }

    /// @notice The NFT symbol — the shared constant `"eStableLP"` for every clone.
    function symbol() public pure override returns (string memory) {
        return "eStableLP";
    }

    function _productName() internal pure override returns (string memory) {
        return "StableLPManager";
    }

    function _defaultName() internal pure override returns (bytes32) {
        return bytes32("Envelop LP Uniswap Manager");
    }

    // ────────── Unlock dispatch (this product's ops) ──────────

    /// @dev Route the stable ops: POKE→claimFees (fee-splitting), ALLOCATE/REINVEST. Withdraw (op 5)
    /// is handled by the base via `super`.
    function _dispatchExtraOp(uint8 op, bytes memory payload) internal override returns (bytes memory) {
        if (op == uint8(Op.POKE)) return _handleClaim(payload);
        if (op == OP_ALLOCATE) return _handleAllocate(payload);
        if (op == OP_REINVEST) return _handleReinvest(payload);
        return super._dispatchExtraOp(op, payload);
    }

    // ────────── allocate ──────────

    /// @notice Auto mode: deploy liquidity per `legs`, drawing from whatever managed stables sit on
    /// the manager's balance; residuals net back to the manager. Owner-or-operator (off-chain sizing).
    /// @param legs Per-pool actions (optional pre-swap + desired add amounts + slippage floor).
    function allocate(AllocLeg[] calldata legs) external onlyAuthorized nonReentrant {
        _validateLegs(legs);
        POOL_MANAGER.unlock(abi.encode(OP_ALLOCATE, abi.encode(_isOwnerCall(), legs)));
        emit Allocated(legs.length);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice Manual mode: deploy a specific just-deposited `stable` (>= `amount` must already sit
    /// on the manager). Guards that the operation draws down ONLY `stable` — no other managed stable
    /// balance may decrease — so deposit-and-allocate can't dip into pre-existing holdings.
    /// Owner-or-operator.
    /// @param stable The managed stable being deployed (the only balance allowed to decrease).
    /// @param amount Amount that must already sit on the manager (snapshot guard reference).
    /// @param legs Per-pool actions (optional pre-swap + desired add amounts + slippage floor).
    function allocateFrom(Currency stable, uint256 amount, AllocLeg[] calldata legs)
        external
        onlyAuthorized
        nonReentrant
    {
        if (!isManagedStable[stable]) revert UnmanagedStable(stable);
        if (amount == 0) revert ZeroAmount();
        uint256 have = stable.balanceOfSelf();
        if (have < amount) revert NotDeposited(stable, have, amount);
        _validateLegs(legs);

        uint256 n = managedStables.length;
        uint256[] memory pre = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            pre[i] = managedStables[i].balanceOfSelf();
        }

        POOL_MANAGER.unlock(abi.encode(OP_ALLOCATE, abi.encode(_isOwnerCall(), legs)));

        // Only `stable` may have decreased; every other managed stable must end >= its pre-balance.
        for (uint256 i = 0; i < n; ++i) {
            Currency c = managedStables[i];
            if (Currency.unwrap(c) == Currency.unwrap(stable)) continue;
            if (c.balanceOfSelf() < pre[i]) revert UnexpectedStableSpend(c);
        }

        emit Allocated(legs.length);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _validateLegs(AllocLeg[] calldata legs) internal view {
        if (legs.length == 0) revert NoLegs();
        for (uint256 i = 0; i < legs.length; ++i) {
            _indexOf(legs[i].poolId); // reverts UnknownPool if not configured
        }
    }

    function _handleAllocate(bytes memory payload) internal returns (bytes memory) {
        (bool byOwner, AllocLeg[] memory legs) = abi.decode(payload, (bool, AllocLeg[]));
        for (uint256 i = 0; i < legs.length; ++i) {
            _allocateLeg(legs[i], byOwner);
        }
        _settleManaged();
        return "";
    }

    /// @dev Per-leg: optional exactIn pre-swap to balance the sides, then add liquidity sized from
    /// the operator's desired amounts. Settlement is deferred to the final `_settleManaged()` pass.
    function _allocateLeg(AllocLeg memory leg, bool byOwner) internal virtual returns (uint128 L) {
        PoolKey memory key = pools[_indexOf(leg.poolId)].key;
        Range memory rg = _range[leg.poolId];
        if (leg.swapAmountIn > 0) {
            BalanceDelta sd = _swap(key, leg.zeroForOne, -int256(leg.swapAmountIn), leg.swapPriceLimit);
            int128 inDelta = leg.zeroForOne ? sd.amount0() : sd.amount1();
            // exactIn: a partial fill (price limit hit) leaves |inDelta| < requested input.
            if (uint256(uint128(-inDelta)) < leg.swapAmountIn) revert SwapSlippage(leg.poolId);
            int128 outDelta = leg.zeroForOne ? sd.amount1() : sd.amount0();
            // Operator swaps must be oracle-vouched (fail-closed); owner has full freedom.
            _guardSwap(byOwner, key, leg.zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
        }
        L = _addLiquidity(
            leg.poolId, key, rg.tickLower, rg.tickUpper, leg.amount0Desired, leg.amount1Desired, leg.minLiquidity
        );
    }

    /// @dev Shared by allocate and reinvest: size liquidity at the current price, add it at the pool's
    /// fixed range `[tickLower,tickUpper]`, and record/merge the position (`salt == poolId`). Settlement
    /// is the caller's job. No per-side spend cap is needed: `L` is sized from `amount{0,1}` at the
    /// on-chain price, so the realized owed is `<= amount{0,1}`.
    function _addLiquidity(
        PoolId id,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiq
    ) internal virtual returns (uint128 L) {
        bytes32 salt = PoolId.unwrap(id);
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(id);
        if (sqrtP == 0) revert PoolUninitialized();

        L = PositionMath.liquidityFromAmounts(sqrtP, tickLower, tickUpper, amount0, amount1);
        if (L < minLiq) revert MinLiquidityNotMet(L, minLiq);

        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(L)), salt: salt
            }),
            ""
        );
        _skimFees(key, fees); // protocol fee on any accrued fees realized by a top-up

        if (_positions[salt].liquidity == 0) {
            _positions[salt] = StoredPosition({
                poolId: id, tickLower: tickLower, tickUpper: tickUpper, liquidity: L, openedAt: uint64(block.timestamp)
            });
            _registerSalt(salt);
        } else {
            _positions[salt].liquidity += L;
        }
    }

    // ────────── reinvest / claimFees ──────────

    /// @notice Collect accrued fees on `salt` to the manager (no principal change). The protocol
    /// fee is skimmed first; the remainder lands on the manager. Owner-or-operator.
    /// @param salt The position key (`== poolId`).
    function claimFees(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokeFromConfig(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @dev POKE handler (replaces the base one): realize fees, skim the protocol cut, net the
    /// remainder to the manager.
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

    /// @notice Compound realized fees of one pool back into its position. The pool is `leg.poolId`.
    /// Owner-or-operator.
    /// @param leg The pool action: which pool (`leg.poolId`), optional balancing pre-swap, and the
    /// `minLiquidity` floor. The add is sized from the realized fee deltas, not `amount{0,1}Desired`.
    function reinvest(AllocLeg calldata leg) external onlyAuthorized nonReentrant {
        _indexOf(leg.poolId); // reverts UnknownPool if not configured
        POOL_MANAGER.unlock(abi.encode(OP_REINVEST, abi.encode(_isOwnerCall(), leg)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleReinvest(bytes memory payload) internal returns (bytes memory) {
        (bool byOwner, AllocLeg memory leg) = abi.decode(payload, (bool, AllocLeg));
        PoolKey memory key = pools[_indexOf(leg.poolId)].key;
        Range memory rg = _range[leg.poolId];
        bytes32 salt = PoolId.unwrap(leg.poolId);

        // Realize fees as a positive caller delta, then skim the protocol cut before compounding.
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: rg.tickLower, tickUpper: rg.tickUpper, liquidityDelta: 0, salt: salt}),
            ""
        );
        _skimFees(key, fees);

        if (leg.swapAmountIn > 0) {
            BalanceDelta sd = _swap(key, leg.zeroForOne, -int256(leg.swapAmountIn), leg.swapPriceLimit);
            int128 inDelta = leg.zeroForOne ? sd.amount0() : sd.amount1();
            int128 outDelta = leg.zeroForOne ? sd.amount1() : sd.amount0();
            // Operator swaps must be oracle-vouched (fail-closed); owner has full freedom.
            _guardSwap(byOwner, key, leg.zeroForOne, uint256(uint128(-inDelta)), uint256(uint128(outDelta)));
        }

        // Size the add from the realized (positive) deltas of the two pool currencies.
        int256 d0 = POOL_MANAGER.currencyDelta(address(this), key.currency0);
        int256 d1 = POOL_MANAGER.currencyDelta(address(this), key.currency1);
        uint128 L = _addLiquidity(
            leg.poolId,
            key,
            rg.tickLower,
            rg.tickUpper,
            d0 > 0 ? uint256(d0) : 0,
            d1 > 0 ? uint256(d1) : 0,
            leg.minLiquidity
        );

        _settleCurrency(key.currency0);
        _settleCurrency(key.currency1);
        emit Reinvested(salt, L);
        return "";
    }
}
