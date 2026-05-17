# Task 004 — `openPosition` (+ `PositionMath` library)

> Commit ref: `#4`
> Branch: `feature/task-004-open-position`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Pool Selection & Validation* (on-chain), § *Architecture Overview* (open block), § *Position Identity: salt-based*
> Depends on: tasks 001–003

## Goal

Ship the headline write path. Operator (or NFT owner) calls `openPosition` with a discovered `PoolKey`, tick range, target liquidity, slippage bounds and salt. The wallet validates the pool, settles from its own balance via the unlock callback, and records the position under `salt`.

## Scope (in this task)

1. **`src/lib/PositionMath.sol`** (new library):
   - `function snapTickLower(int24 tick, int24 spacing) internal pure returns (int24)`.
   - `function snapTickUpper(int24 tick, int24 spacing) internal pure returns (int24)`.
   - `function liquidityFromAmounts(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1) internal pure returns (uint128)` — thin wrapper around `LiquidityAmounts` from `@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol`.
   - `function requireValidTickRange(int24 tickLower, int24 tickUpper, int24 spacing) internal pure` — asserts `tickLower < tickUpper`, both multiples of `spacing`, within `MIN_TICK`/`MAX_TICK`.
2. **`openPosition` external entrypoint** in `src/UniSmartWallet.sol`:
   ```solidity
   function openPosition(
       PoolKey calldata key,
       int24 tickLower,
       int24 tickUpper,
       uint128 liquidity,
       bytes32 salt,
       uint128 minPoolLiquidity,
       uint128 amount0Max,
       uint128 amount1Max
   ) external onlyAuthorized nonReentrant;
   ```
   Validation order (cheapest first):
   1. `positions[salt].liquidity == 0` (salt collision).
   2. `liquidity > 0`.
   3. `_isHookAllowed(key.hooks)` (from task 003).
   4. `PoolId id = key.toId(); (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(POOL_MANAGER, id); require(sqrtPriceX96 != 0, "PoolUninit");`.
   5. If `minPoolLiquidity != 0`: `require(StateLibrary.getLiquidity(POOL_MANAGER, id) >= minPoolLiquidity, "PoolThin");`.
   6. `PositionMath.requireValidTickRange(...)`.
   Then `POOL_MANAGER.unlock(abi.encode(Op.OPEN, abi.encode(key, tickLower, tickUpper, liquidity, salt, amount0Max, amount1Max)))`.
3. **`_handleOpen` callback body**:
   - `poolManager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower, tickUpper, liquidityDelta: int256(uint256(liquidity)), salt}), "")` → `(BalanceDelta delta, BalanceDelta feesAccrued)`.
   - `uint128 owed0 = uint128(uint256(-int256(delta.amount0())))` (delta is negative when we owe); same for `amount1`.
   - `require(owed0 <= amount0Max && owed1 <= amount1Max, "Slippage")`.
   - Settle via `CurrencySettler.settle(key.currency0, POOL_MANAGER, address(this), owed0, false)` and same for `currency1` (handle native by checking `Currency.isAddressZero`).
   - Record `positions[salt] = Position({key, tickLower, tickUpper, liquidity, openedAt: uint64(block.timestamp)})`; `openSalts.push(salt)`.
   - Emit `PositionOpened(salt, key.toId(), tickLower, tickUpper, liquidity, owed0, owed1)`.
4. **Tests** appended to `test/UniSmartWallet.t.sol`:
   - `test_openPosition_byNFTOwner_succeeds`
   - `test_openPosition_byOperator_succeeds`
   - `test_openPosition_byNonAuthorized_reverts`
   - `test_openPosition_saltCollision_reverts`
   - `test_openPosition_insufficientBalance_reverts`
   - `test_openPosition_disallowedHook_reverts`
   - `test_openPosition_allowedHook_succeeds`
   - `test_openPosition_uninitializedPool_reverts`
   - `test_openPosition_belowMinLiquidity_reverts`
   - `test_openPosition_exceedsAmount0Max_reverts`
   - `test_openPosition_exceedsAmount1Max_reverts`
   - Unit tests for `PositionMath` (separate file `test/PositionMath.t.sol` or inline): tick snapping, liquidity-from-amounts symmetry, invalid range reverts.

## Out of scope

- Close / decrease / poke external entrypoints + callback bodies → task 005.
- Fork-level real-pool integration → task 007.

## Files to add / change

| Path | Change |
|---|---|
| `src/UniSmartWallet.sol` | Add `openPosition`, `_handleOpen`, settlement helpers, events |
| `src/lib/PositionMath.sol` | New library |
| `test/UniSmartWallet.t.sol` | Append open-position tests; deploy a v4-core `PoolManager` and a hookless pool in `setUp` (using `Deployers` from `v4-core/test/utils` if convenient) |
| `test/PositionMath.t.sol` | New unit tests for the math library |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path test/UniSmartWallet.t.sol -vvv
forge test --match-path test/PositionMath.t.sol -vvv
```

All listed tests pass; prior tests still pass.

## Notes for implementer

- Pull the local `PoolManager` deploy + pool initialization helpers from `lib/v4-hooks-public/lib/v4-core/test/utils/Deployers.sol` to keep `setUp` short.
- `CurrencySettler` is at `lib/v4-hooks-public/lib/v4-core/test/utils/CurrencySettler.sol`. Native ETH must be forwarded as `msg.value` from the wallet's own balance — use `Currency.isAddressZero` to branch.
- Salt-collision check uses `liquidity == 0` as the "empty" sentinel; this is sufficient because the operator must always pass `liquidity > 0` (validated in step 2).
- Keep `_handleOpen` strictly internal; only the `unlockCallback` dispatcher in task 003 should reach it.
