# task_029 — Unify `withdrawTo` across managers into `BaseLPManager`

**Priority:** Medium · **Effort:** M · **Branch:** `task/029-unify-withdraw` · **Depends on:** task_025 (`BaseLPManager`), task_026 (`VolatileLPManager`)

## Goal
`StableLPManager` and `VolatileLPManager` each carry a near-duplicate indirect-drain path
(`withdrawTo` + handler + pull helper + withdraw structs + op code). They diverge only in how a
pull addresses a position:

- Stable `WithdrawStep{PoolId poolId}` — `salt == poolId`, ticks read from `_range[poolId]`.
- Volatile `VWithdrawStep{bytes32 salt}` — ticks read from `_positions[salt]`.

But **both** products store the full record in the shared `mapping(bytes32 => StoredPosition)`
(`poolId` + `tickLower/tickUpper` populated at add time), so a single **salt-keyed** pull that reads
`StoredPosition` works for both. For Stable `salt == poolId` and the stored ticks equal `_range`, so
the behaviour is identical. Consolidate the whole path into `BaseLPManager`.

## Decisions (confirmed)
- Shared `WithdrawToParams` **drops** `reinvestRemainder` (dead phase-1 no-op; Volatile never had it).
- Value field named **`requestedCurrency`** (neutral; not stable-specific).
- **Full hoist** into `BaseLPManager`: structs + `withdrawTo` + `_handleWithdrawTo` +
  `_pullLiquidity(salt, liq)` + one op code.

## Changes
- **`BaseLPManager.sol`**
  - `WithdrawStep{bytes32 salt; uint128 liquidityToPull}` (was `PoolId poolId`). Calldata layout is
    unchanged for Stable (`PoolId` is a `bytes32` value type).
  - `WithdrawToParams{recipient, requestedCurrency, amount, WithdrawStep[] pulls, WithdrawSwap[] swaps}`
    (drop `reinvestRemainder`).
  - Add `OP_WITHDRAW_TO = 5`; add a `_dispatchExtraOp` override that handles it and `super`-falls
    through (so both products route withdraw to the base).
  - Move in `withdrawTo` (owner-only), `_handleWithdrawTo`, and `_pullLiquidity(bytes32 salt, uint128
    liq)` — the Volatile variant (reads `StoredPosition` for pool key + ticks). Salt-based validation
    (`UnknownPosition` when `liquidity == 0`; `DeltaExceedsLiquidity` on over-pull).
  - Import `ModifyLiquidityParams` from `@uniswap/v4-core/src/types/PoolOperation.sol`.
- **`StableLPManager.sol`** — delete `OP_WITHDRAW_TO`, the `WITHDRAW_TO` dispatch branch, and the whole
  `withdrawTo`/`_handleWithdrawTo`/`_pullLiquidity` block. `_range` stays (allocate/reinvest use it).
- **`VolatileLPManager.sol`** — delete `OP_WITHDRAW_TO_V`, the `VWithdraw*` structs, the dispatch
  branch, and `withdrawTo`/`_handleWithdrawToV`/`_pullLiquidityV`.
- **Tests / spec** — repoint Stable withdraw tests to salt-keyed `WithdrawStep{salt}` and drop the
  trailing `reinvestRemainder` arg; repoint Volatile tests from `VWithdraw*` → `Withdraw*`; update
  `tasks/spec_StableLPManager.md` (`requestedCurrency`, salt-keyed pulls, no `reinvestRemainder`).

## Behavioural note
Stable loses its `UnknownPool` pre-check in the pull loop (an unconfigured pool now surfaces as
`UnknownPosition`, since a position can't exist in an unconfigured pool). Equivalent coverage.

## Size note
The win is source-level dedup + a single audited withdraw path, **not** bytecode. Solidity flattens
inherited code into each contract, so each manager still carries one copy; the extra base
`_dispatchExtraOp` layer + the slightly heavier stored-position pull add a few bytes:
StableLPManager 22,851 → 23,003 (+152), VolatileLPManager 23,237 → 23,249 (+12). Both keep a
comfortable EIP-170 margin (1,573 / 1,327 B).

## Gate (all green)
- `forge build --sizes` — both clones `< 24 576` B (margins above).
- `forge fmt --check` — clean.
- `forge test` — 116 passed, 2 skipped (fork tests, need `BASE_RPC`).
