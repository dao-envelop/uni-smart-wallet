# Task 016 — Audit remediation (LOW findings)

Follow-up to the deep multi-agent security audit (see `AUDIT-REPORT.md`). The HIGH finding (protocol-fee
treasury blocklist → locked principal) was already fixed in `#15` (ERC-6909 claims skim). This task
applies the three clean LOW fixes and documents the rest.

## Code fixes

1. **`SingletonNFTOwned` — operator list splice-on-disable.** `setOperator(op,false)` now removes `op`
   from `_operatorList` via a 1-based index map (`_operatorIndexPlusOne`, swap-and-pop — mirrors
   `V4PositionManager._removeSalt`), instead of only flipping the bool. `_clearOperators` (run on every
   NFT transfer) therefore iterates only ACTIVE operators. Removes the unbounded-growth vector where
   enable/disable churn could grow the list until the per-transfer clear loop OOGs and bricks the
   ownership handover.
2. **`StableLPManager._skimFee` — round the protocol cut UP** (`(_pos(fee)*PROTOCOL_FEE_BPS + 9_999) /
   10_000`, inline ceil — avoids pulling in `FullMath.mulDivRoundingUp`, which cost ~150 B and nearly
   breached EIP-170). Favors the protocol; removes the sub-threshold zero-skim bias.
3. **`StableLPManager._addLiquidity` — `if (sqrtP == 0) revert PoolUninitialized();`** (error inherited
   from base). Parity with `V4PositionManager._openPosition`; rejects allocating into a
   configured-but-uninitialized pool.

## Documented (no code change)
- Managed currencies must be standard ERC-20 — **no fee-on-transfer, no rebasing** (the settle/snapshot/
  delivery accounting assumes `received == sent`).
- auto-`allocate` may deploy the manager's full idle balance (operator scope) — by design.
- `withdrawTo` swaps: the operator MUST set a tight `sqrtPriceLimitX96` (MEV/slippage discipline; each
  swap is already price-bounded by it, so no extra min-output field was added).
- Clones must only be created via `StableLPFactory` (clone+initialize is atomic there).

## Tests
- `StableLPManagerAuditFixes.t.sol`: operator splice keeps the active set correct and still auto-clears
  on transfer; enable/disable churn no longer bricks transfer; allocate into an uninitialized pool
  reverts `PoolUninitialized`.
- Fee round-up is covered by `StableLPManagerProtocolFee.t.sol`'s 90/10 split assertion.

## Result
118 tests pass, 1 fork skipped without `BASE_RPC`. `StableLPManager` ~24,399 bytes — **EIP-170 margin
~177 B** (tight; further growth needs `optimizer_runs`↓ or a delegatecall-library split).

## Verification
```bash
forge fmt --check
forge build --sizes
forge test
```
