# task_027 — External price-oracle guard for VolatileLPManager (with amountMax+minOut fallback)

**Priority:** High · **Effort:** M · **Depends on:** task_026 (VolatileLPManager)

## Goal
Add an **external, pluggable price guard** for the volatile manager's on-chain swaps (allocate
pre-swap, recenter rebalance). It is the **primary** protection against a loose operator param being
sandwiched; the operator-supplied **`amountMax` + `minAmountOut` stay as the always-on fallback**
(they already gate every swap/add). When the oracle can't answer (no feed / stale), the manager
degrades to that baseline — never blocks a legitimate op.

## Hard constraint
`VolatileLPManager` is at **24321/24576 (255 B free)** after task_026. The oracle logic must live
**outside** the manager. The manager only gains a settable `address priceOracle` + a single external
call in the swap path — keep the added bytecode tiny (or drop `optimizer_runs` to 100 for headroom).

## Design
- **`IPriceOracle`** interface (new): a `view` check the manager calls around a swap, e.g.
  `check(PoolKey key, bool zeroForOne, uint256 amountIn, uint256 amountOut)`. It reverts
  (`PriceOutOfBounds`) if the realized price deviates beyond the oracle's tolerance from its
  reference; it **returns without reverting when it has no fresh reference** (⇒ fallback).
- **Manager wiring:** `address public priceOracle` (owner-settable via an owner-only setter);
  `_guardSwap(key, zeroForOne, amountIn, amountOut)` = `if (priceOracle != 0) IPriceOracle(...).check(...)`.
  Call it right after each `_swap` in `_allocateLegV` / `_rebalanceSwap`. Minimal manager code.
- **Concrete oracle (ship one):** pending the source decision below. The interface is the key
  deliverable; the impl is swappable per deployment.

## Open decision (oracle source) — confirm before building the impl
1. **External feed adapter (Chainlink/Pyth-style).** Reuse the Envelop `EnvelopOraclePyth` pattern
   (sibling repo): per-token USD feeds → derive the pair reference price → bound the swap. Robust
   cross-block, but needs a feed per token (many volatile tokens lack feeds → fallback).
2. **V4 pool TWAP.** Bound the swap against a time-weighted pool price. V4 has no built-in oracle
   (needs a truncated-oracle hook or the manager tracking observations) — heavier, but works for any
   pool without external feeds.
3. **Slot0-deviation sanity guard (v1-lean).** Bound the swap's realized price against the pool's
   pre-swap `slot0` by a max-deviation. Catches gross in-tx sandwiches cheaply; `slot0` itself is
   manipulable across blocks, so weaker than 1/2 — but tiny and a clear improvement over none.

## Steps (commit between; keep green + size-gated < 24576)
1. `IPriceOracle` interface + manager wiring (`priceOracle` setter + `_guardSwap` calls). Size check.
2. Concrete oracle impl (chosen source) + its own unit tests.
3. Integration tests: oracle blocks an out-of-bounds swap; absent/stale oracle ⇒ fallback to
   amountMax+minOut; owner-only setter.

## Acceptance
- `forge build --sizes` < 24576 (VolatileLPManager); `forge fmt --check`; `forge test` green
  (new oracle suites + all existing).
- Oracle is pluggable (interface), owner-settable, and enforced on volatile swaps with a clean
  fallback when it can't answer.
