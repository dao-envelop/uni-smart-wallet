// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseLPManager} from "./BaseLPManager.sol"; // for `@inheritdoc` only — already in the chain
import {VolatileLPManager} from "./VolatileLPManager.sol";

/// @title OpenVolatileLPManager
/// @notice {VolatileLPManager} with **no hook policy at all**: any pool may be configured, including one
/// whose hook can rewrite balance deltas. Everything else — `initialize` / `InitParams`, allocate,
/// recenter, claimFees, withdrawTo, the fee skim, the oracle guard on operator swaps — is inherited
/// unchanged, so this is the same product with one restriction lifted.
///
/// It exists as a separate implementation rather than a flag on the other two for three reasons: each
/// implementation gets its own EIP-170 budget (`StableLPManager` has ~482 B left, so a per-manager flag
/// would not fit); the choice is then a deployment-time fact bound in the code the clone points at,
/// with no setter and nothing to flip mid-flight; and `LPManagerFactory`'s owner-curated
/// `isImplementation` allowlist already makes "pick this implementation" the explicit opt-in.
/// Hookless {VolatileLPManager} remains the default that a UI should offer first.
///
/// ─────────────────────────────────────────────────────────────────────────────────────────────────
/// WHAT THE OWNER IS ACCEPTING BY CHOOSING THIS IMPLEMENTATION
///
/// For this product the invariant "the manager's own code protects the principal" **does not hold**. It
/// holds exactly as far as the chosen hook is honest. Specifically:
///
/// 1. A hook holding `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` (bit 0 of its address) can skim principal on
///    the way out, undetected. `BaseLPManager._pullLiquidity` discards the caller `BalanceDelta`
///    entirely and keeps only `feesAccrued`; `WithdrawStep` has no `amount*Min`; the sole quantitative
///    backstop is the aggregate `AmountNotDelivered` check on what reaches the recipient, so any
///    shortfall below that is netted silently by `_settleManaged`. This is audit `2026-05-17` [H-6],
///    reachable again here by construction.
/// 2. A hook that simply reverts on `beforeRemoveLiquidity` can brick `withdrawTo` for its pool and trap
///    the principal there. The owner-only `executeEncodedTxBatch` escape hatch remains, but that is a
///    manual unwind, not a supported path.
/// 3. Swap-delta hooks (`BEFORE/AFTER_SWAP_RETURNS_DELTA`) reach the withdraw conversion swaps, which
///    carry a `sqrtPriceLimitX96` but **no** `minAmountOut` and do not pass through `_guardSwap`.
///
/// What is NOT on that list, despite hooks now running inside our `unlock`: re-entrancy. v4 reverts a
/// nested `unlock` (`AlreadyUnlocked`), the callback target is hardcoded to the caller so it cannot be
/// retargeted at us, a forged direct call is rejected by `NotPoolManager`, and every entry point carries
/// `nonReentrant` on a shared guard. Audit `2026-05-17` [M-3] claimed otherwise and is resolved NOT
/// APPLICABLE (task_044) — its recommended fix would in fact brick every operation. So the residual here
/// is the delta problem in 1-3, not re-entry.
///
/// Pools are still deduped by `poolId` and capped at `MAX_POOLS`, and the hook set is fixed at
/// `initialize` — an operator can only ever name a `PoolId` already in the configured set.
/// ─────────────────────────────────────────────────────────────────────────────────────────────────
contract OpenVolatileLPManager is VolatileLPManager {
    /// @notice A hooked add billed the manager more than the caller offered to spend.
    error OwedExceedsDesired();

    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) VolatileLPManager(poolManager_, treasury_) {}

    // ────────── Hook policy ──────────

    /// @dev No policy: every pool is accepted, hooked or not. Flipping this constant IS the whole
    /// feature — see the contract-level notes for what it costs. Because the base predicate is `pure`,
    /// solc folds `!true && …` away, so the gate is absent from this contract's code rather than
    /// branched around at runtime.
    /// @inheritdoc BaseLPManager
    function _hooksAllowed() internal pure override returns (bool) {
        return true;
    }

    // ────────── Product identity ──────────

    /// @inheritdoc BaseLPManager
    function ORACLE_TYPE() public pure override returns (uint256) {
        return 3002;
    }

    /// @notice The NFT symbol — the shared constant `"eOpenLP"` for every clone.
    function symbol() public pure override returns (string memory) {
        return "eOpenLP";
    }

    /// @inheritdoc VolatileLPManager
    /// @dev Enforces the spend cap the other products get for free. Elsewhere "owed ≤ desired" holds by
    /// construction: L is sized from the desired amounts at the price the oracle just vouched for, and
    /// nothing can run between the two. Here something can — v4 invokes `beforeAddLiquidity` inside
    /// `modifyLiquidity` while the lock is still open, so a hook may re-enter `PoolManager.swap`, move
    /// the price, let the add be priced against it, and put the price back before returning. That took
    /// 44.997% of a portfolio in one approved call (audit 2026-09-04, R-1).
    ///
    /// Re-reading `slot0` afterwards does not catch it: by then the price is home again. The bill is the
    /// only thing that keeps the evidence, so the bill is what gets checked.
    function _checkOwed(BalanceDelta principal, uint256 amount0, uint256 amount1) internal pure override {
        if (_over(principal.amount0(), amount0) || _over(principal.amount1(), amount1)) {
            revert OwedExceedsDesired();
        }
    }

    /// @dev One side of the spend cap. `owed` is the manager's delta: negative is what it pays.
    function _over(int128 owed, uint256 desired) private pure returns (bool) {
        return owed < 0 && uint256(uint128(-owed)) > desired;
    }

    function _productName() internal pure override returns (string memory) {
        return "OpenVolatileLPManager";
    }

    function _defaultName() internal pure override returns (bytes32) {
        return bytes32("Envelop Open LP Manager");
    }
}
