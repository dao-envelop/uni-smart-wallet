// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title V4PositionManager
/// @notice Reusable Uniswap V4 interaction layer: the `PoolManager.unlock` dispatcher shell, the
/// swap/settle/take primitives, the salt registry, and the canonical `Position` **view type**.
/// @dev Config-agnostic and auth-agnostic on purpose. It owns NO position storage: subclasses keep
/// their own store (a manager reconstructs a position's `PoolKey` from its configured-pool set; the
/// test harness keeps the full key locally) and implement `positionOf`. The PoolManager is an
/// `immutable` set via this base's constructor: clones don't run constructors, but immutables live in
/// the implementation's code and are read through delegatecall, so a single shared `POOL_MANAGER`
/// works for both direct deploys and clones.
abstract contract V4PositionManager is IUnlockCallback, ReentrancyGuard {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;

    /// @notice The V4 PoolManager (per-chain singleton). Set once in the constructor; shared by all
    /// clones of a clone-deployed subclass.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Set the immutable V4 PoolManager shared by this contract (and all clones of a subclass).
    /// @param poolManager_ The per-chain Uniswap V4 PoolManager singleton.
    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

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

    // ────────── Position view type ──────────

    /// @notice The canonical position shape returned by `positionOf` and read by the descriptor / lens
    /// / valuation contracts. NOTE: this is a **view/return type**, not the on-chain storage layout —
    /// managers store a leaner record (poolId instead of the full key) and reconstruct `key` here.
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 openedAt;
    }

    /// @dev Payload shared by the close/decrease/poke handlers: a fully-resolved position (with key)
    /// plus the liquidity delta to remove (0 for poke ⇒ fees only).
    struct RemoveParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 deltaLiquidity;
        bytes32 salt;
    }

    // ────────── Salt registry ──────────

    /// @notice Enumerable list of salts with an open position (for portfolio iteration).
    bytes32[] public openSalts;
    /// @dev 1-based index into openSalts so 0 means "not present". Enables O(1) splice.
    mapping(bytes32 => uint256) internal _saltIndexPlusOne;

    // ────────── Events ──────────

    /// @notice Emitted when fees only are harvested (poke) for `salt`.
    /// @param salt The position key.
    /// @param fees0 currency0 fees collected.
    /// @param fees1 currency1 fees collected.
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

    // ────────── Unlock callback (extensible dispatcher) ──────────

    /// @notice PoolManager unlock callback. The base defines no ops of its own — it decodes a leading
    /// `(uint8 op, bytes payload)` and forwards to `_dispatchExtraOp`, which subclasses override to
    /// route their own ops against the shared primitives. Reverts unless called by the PoolManager.
    /// @param data ABI-encoded `(uint8 op, bytes payload)` produced by this contract before `unlock`.
    /// @return The handler's return data (settlement happens inside the handlers).
    function unlockCallback(bytes calldata data) external virtual override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        return _dispatchExtraOp(op, payload);
    }

    /// @dev Override to handle subclass-specific op codes. The second arg is the op payload (unnamed
    /// here since the base default ignores it). Default: reject.
    /// @param op The op code that the base dispatcher did not recognize.
    /// @return The handler's return data (the base default reverts instead).
    function _dispatchExtraOp(uint8 op, bytes memory) internal virtual returns (bytes memory) {
        revert UnknownOp(op);
    }

    // ────────── Salt registry helpers ──────────

    /// @dev Register a new salt in the open-position index (push + 1-based index). Shared by every
    /// subclass flow so the O(1) registry bookkeeping lives in one place.
    /// @param salt The position key to add to `openSalts`.
    function _registerSalt(bytes32 salt) internal {
        openSalts.push(salt);
        _saltIndexPlusOne[salt] = openSalts.length;
    }

    /// @dev O(1) swap-and-pop removal from openSalts using _saltIndexPlusOne.
    /// @param salt The position key to remove from `openSalts`.
    function _removeSalt(bytes32 salt) internal {
        uint256 idxPlusOne = _saltIndexPlusOne[salt];
        if (idxPlusOne == 0) return; // defensive — shouldn't happen if the position was set
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
    /// @param key The pool to swap in.
    /// @param zeroForOne True to swap currency0 → currency1, false for the reverse.
    /// @param amountSpecified Negative ⇒ exact-in, positive ⇒ exact-out.
    /// @param sqrtPriceLimitX96 Price-limit slippage bound for the swap.
    /// @return delta The caller's resulting balance delta (unsettled).
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        delta = POOL_MANAGER.swap(key, params, "");
    }

    /// @dev Pay an owed currency to the PoolManager from this contract's balance. Uses the
    /// production v4-core `CurrencyLibrary.transfer` (not the test `CurrencySettler`), so tokens
    /// whose `transfer` returns no data — e.g. USDT — settle correctly. Mirrors v4-periphery's
    /// `DeltaResolver._settle`.
    /// @param currency The currency owed to the PoolManager.
    /// @param amount The amount to pay (no-op when zero).
    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.sync(currency);
        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            currency.transfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    /// @dev Withdraw a credited currency from the PoolManager to `recipient`. The
    /// arbitrary-recipient form is the v4-native primitive for delivering funds to an
    /// address without routing them through this contract's ERC-20 balance.
    /// @param currency The credited currency to withdraw.
    /// @param recipient Address that receives the ERC-20 / native tokens.
    /// @param amount The amount to withdraw.
    function _take(Currency currency, address recipient, uint256 amount) internal {
        currency.take(POOL_MANAGER, recipient, amount, false);
    }

    /// @dev Like {_take} but credits `recipient` with ERC-6909 claims (a PoolManager-internal
    /// balance) instead of an ERC-20 transfer. Used for fee skims so a token blocklist/pause on
    /// `recipient` cannot revert the unlock; `recipient` redeems the claims to ERC-20 later.
    /// @param currency The credited currency to take as claims.
    /// @param recipient Address credited with the ERC-6909 claims.
    /// @param amount The claim amount.
    function _takeClaim(Currency currency, address recipient, uint256 amount) internal {
        currency.take(POOL_MANAGER, recipient, amount, true);
    }

    // ────────── Views ──────────

    /// @notice The stored position for a salt (zero-liquidity struct if none). Subclasses implement
    /// this over their own storage, reconstructing `key` as needed.
    /// @param salt The position key.
    /// @return The {Position} record (pool key, ticks, liquidity, openedAt).
    function positionOf(bytes32 salt) external view virtual returns (Position memory);

    /// @notice Number of currently open positions.
    /// @return The length of `openSalts`.
    function openPositionCount() external view returns (uint256) {
        return openSalts.length;
    }
}
