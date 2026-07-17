# task_026 — VolatileLPManager (arbitrary-pair manager on BaseLPManager)

**Priority:** High · **Effort:** L · **Depends on:** task_025 (`BaseLPManager`)

## Goal
Add `VolatileLPManager` — a {BaseLPManager} product for **arbitrary (volatile) asset pairs**. Reuses
the base's clone-init, `managedStables` union, protocol-fee skim, indirect-drain machinery, settlement
primitives, tokenURI, and auth. Adds what volatile pairs need beyond the stable model:
- **Per-call tick ranges** and **salt-keyed multi-position** (several positions per pool), vs the
  base/stable `salt == poolId` fixed-range model.
- **`amount0Max`/`amount1Max`** slippage caps on adds (owed is price-sensitive when a range can go
  one-sided) + **`minAmountOut`** on pre-swaps.
- A single-call **`recenter`** op (pull → balancing swap → re-add at a new range).
- External interface kept ≈ StableLPManager where it can be (`withdrawTo`/`reinvest`/`claimFees`/
  `setOperator`/`initialize`/views identical); differences confined to the allocate/recenter leg
  structs. Price safety oracle is task_027 (this task ships the amountMax+minOut baseline).

## Design (salt/range model)
- **Keep configured pools** (base `initialize` / `pools` / `managedStables`) — needed for settlement,
  `withdrawTo`, and the managed set. Volatile pools are still hookless, validated at init. What
  changes is that positions are **salt-keyed** (caller-chosen `bytes32 salt`, base registry already
  supports arbitrary salts) with **per-call ranges**, so a pool can hold many ranges at once.
- Volatile adds its **own ops** (op codes ≥ 7) routed via `_dispatchExtraOp`, with its own leg
  structs — it does NOT reuse the base `allocate(AllocLeg[])`/OP_ALLOCATE (that's the fixed-range,
  poolId-salt model). `withdrawTo`/`reinvest`/`claimFees` that key by `poolId` are overridden to key
  by `salt` (or given salt-carrying variants).

## Base seams to add (behavior-preserving for StableLPManager)
`BaseLPManager` was extracted with the stable model; give it the extension points volatile needs
without changing stable behavior:
1. `unlockCallback` → route **unknown** ops to `_dispatchExtraOp(op, payload)` instead of
   `revert UnknownOp` (StableLP uses no extra ops → `_dispatchExtraOp` default still reverts, so
   identical behavior). This lets VolatileLPManager add `recenter`/`allocate` ops.
2. Make the position-key-dependent internals overridable where volatile diverges (e.g. a virtual
   `_positionSalt` / salt-carrying withdraw+reinvest paths), or add volatile-specific ops that reuse
   only the base primitives. Prefer additive seams over rewriting stable code.
   Every base edit must keep the StableLP* suites green and StableLPManager ≤ 24576.

## Product identity (subclass supplies)
`ORACLE_TYPE()` (Envelop tag for the volatile product), `symbol()` (e.g. `"eVolLP"`),
`_productName()` = `"VolatileLPManager"`, `_defaultName()`.

## Steps (commit between; keep green + size gated)
1. Base seam: `unlockCallback` → `_dispatchExtraOp` fallback (+ any minimal virtualization). StableLP
   suites green, sizes unchanged.
2. `VolatileLPManager` skeleton: subclass BaseLPManager, product identity, compiles.
3. Volatile `allocate` (per-call ranges + salt + `amountMax` + `minAmountOut`) via a new op + handler,
   reusing base `_swap`/`_settle`/`_skimFees`/`_settleManaged`/registry. Unit tests.
4. Salt-keyed `withdrawTo` / `reinvest` / `claimFees` (override or variant). Tests.
5. `recenter(salt, newTickLower, newTickUpper, ...)` op. Tests (incl. one-sided → recenter).
6. Fork test on a volatile pool. Size gate (`forge build --sizes` < 24576).

## Acceptance
- `forge build --sizes` all < 24576; StableLPManager unchanged & green.
- `forge fmt --check`, `forge test` (new Volatile* suites + all StableLP* suites) green.
- VolatileLPManager: per-call ranges, multi-position per pool, amountMax + minOut enforced, recenter
  works; interface matches StableLPManager except the allocate/recenter leg structs.
