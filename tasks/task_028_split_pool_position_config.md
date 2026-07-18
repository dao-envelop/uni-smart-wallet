# task_028 — Split pool-identity vs position-range across base and managers

**Priority:** Medium · **Effort:** L · **Branch:** `task/028-split-pool-position-config`

## Goal
`BaseLPManager`/`V4PositionManager` were extracted from Stable, so their shared structs mix
pool-level and position-level attributes. Audit of the two products found a field mismatch:

- `PoolConfig.tickLower/tickUpper` — used by Stable (fixed per-pool range), **dead for Volatile**
  (per-call ranges) yet validated + stored at init (footgun API).
- `Position.key` (3 slots) — **redundant** for Stable (`salt == poolId` ⇒ key is in `pools`),
  **essential** for Volatile (`salt ≠ poolId`, many positions/pool; only link to the pool).

Split the concerns cleanly:
- Base-base `V4PositionManager`: config-agnostic primitives + `Position` **view type** + abstract
  `positionOf`; position storage + poke move out.
- `BaseLPManager`: `PoolConfig { PoolKey key }` (drop ticks); `StoredPosition { PoolId poolId; ticks;
  liquidity; openedAt }` (2 slots, was 4); `positionOf` reconstructs `key` from config; `_pokeFromConfig`.
- `StableLPManager`: own `InitParams` with per-pool range → `_range[poolId]`; `salt == poolId`.
- `VolatileLPManager`: own `InitParams` with **keys only** (no ticks); stores `poolId` in the position.
- `V4PositionOpsHarness` (test-only): self-contained full-`Position` storage + local poke.

## Result
−2 slots/position for both managers, −1 slot/pool in Volatile config, no dead fields, honest init APIs,
`Position.key` no longer stored (reconstructed in `positionOf`). External `positionOf`/`Position` type
unchanged ⇒ `UniLens`/`WalletPositionDescriptor`/`PositionState` untouched.

## Also
- Remove stale `UniSmartWallet` references from live code/docs (contract was deleted in task_025).

## Gate
`forge build --sizes` (Stable < 24 576), `forge test`, `forge fmt --check`.
