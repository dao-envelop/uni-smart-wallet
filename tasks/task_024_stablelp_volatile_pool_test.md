# Task 024 — Diagnostic test: StableLPManager on a volatile pool (ETH/USDT stand-in)

## Goal

Prove, in code, why `StableLPManager` is a stable-only product and cannot safely serve arbitrary /
volatile assets. Motivation: the repo's only ETH coverage (`test/StableLPManagerNative.t.sol`) models
native ETH as a *pegged* currency (pool at 1:1, narrow `[-60, 60]` band); there was no test of a
volatile pair where the price is off-peg or leaves the configured band.

Diagnostic only — **no contract changes**. The tests pass; the degradation they capture is the expected
behavior of a fixed-range design.

## Changes

- `test/StableLPManagerVolatilePool.t.sol` (new): standalone scaffold (PoolManager +
  `PoolModifyLiquidityTest` seed + `PoolSwapTest`), two ERC20s as an ETH/USDT stand-in, manager cloned
  with the stable `[-60, 60]` band. Two cases:
  - `test_allocate_offPeg_mintsLopsidedPosition` — pool initialized at tick 6000 (band entirely below
    market): `allocate` deploys only one side (`getLiquidityForAmounts` sizes from currency1 alone),
    opening a 100%-single-asset position.
  - `test_positionExitsRange_afterVolatileSwap_earnsNoFees_cannotRecenter` — position opened in-range at
    tick 0, then a swap walks the price above the band; subsequent out-of-range volume yields zero fees,
    and a fresh `allocate` reuses the same stuck `[-60, 60]` ticks (no setter ⇒ recenter needs a redeploy).

## Notes

- Reuses existing idioms: seed pattern from `test/helpers/StableLPTestBase.sol`, swap-router pattern
  from `test/PositionState.t.sol` / `test/UniSmartWalletExitPositions.t.sol`.
- Confirms the audit's documented MEDIUM (`tasks/spec_StableLPManager.md:193`, "relies on stable pools
  being deep/pegged"): arbitrary/volatile assets need per-call/updatable ranges + `amount*Max` + active
  recentering — the `UniSmartWallet.openPosition` model — not `StableLPManager`.

## Verify

```bash
forge test --match-path test/StableLPManagerVolatilePool.t.sol -vvv   # 2 passed
forge fmt --check
```
