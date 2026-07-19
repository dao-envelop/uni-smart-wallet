# Task 034 — Reject zero-liquidity adds (audit L-REG-1)

Follow-up to `audits/2026-07-18`, finding **L-REG-1**. When `minLiquidity == 0`, the `if (L < minLiq)`
check (`0 < 0` = false) let an `L == 0` add through: on a fresh salt this registered a zero-liquidity
"ghost" position in `openSalts`, and re-`allocate`-ing a ghost salt could double-`_registerSalt`. Only
off-chain/UI impact (no on-chain fund path reads `openSalts`; liquidity accounting keys off
`_positions[salt]`), hence LOW — but worth removing the ghost class entirely.

## Fix
Add `if (L == 0) revert ZeroLiquidity();` right after the `minLiq` check in both shared add-helpers
(`ZeroLiquidity` already exists in `V4PositionManager`, inherited):
- `src/StableLPManager.sol` — `_addLiquidity` (shared by allocate + reinvest).
- `src/VolatileLPManager.sol` — `_addLiquidityAt` (shared by allocate + recenter).

**Behavioral note:** `allocate`/`reinvest`/`recenter` calls that would deploy nothing (zero desired
amounts / no fees to compound / freed ~0) now **revert `ZeroLiquidity`** instead of silently no-op-ing and
creating a ghost. Legitimate ops yield `L > 0` and are unaffected.

## Tests
- `test/StableLPManagerAudit*` or a small new test: allocate with `amount0Desired==amount1Desired==0` and
  `minLiquidity==0` reverts `ZeroLiquidity`; `openPositionCount()` does not grow; a normal allocate still
  opens a position. (Volatile analog in its allocate suite.)

## Verification
```bash
forge fmt --check
forge build --sizes
forge test -vvv
```
</content>
