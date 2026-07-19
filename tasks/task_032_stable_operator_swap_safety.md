# Task 032 — Operator swap safety for StableLPManager (audit M-VOL-2)

Extends task_031 (Volatile) to close **M-VOL-2** on `StableLPManager`: a compromised operator can bleed
**idle balances + fees** through the `allocate` pre-swap and the `reinvest` swap, whose slippage bounds are
operator-supplied (the `reinvest` swap has no output check at all). Stable has **no** operator-callable
principal-removal path (that stays `withdrawTo`, owner-only), so the exposure is idle+fees, not principal —
but the same owner/operator-asymmetric guard should apply.

## Design — hoist the guard into `BaseLPManager` (shared by both products)

The operator/owner swap guard is a security primitive; keep **one** canonical copy. Move
`priceOracle` / `setPriceOracle` / `PriceOracleSet` / `_isOwnerCall` / `_guardSwap` /
`OperatorSwapGuardRequired` / `OperatorSwapUnverified` from `VolatileLPManager` into `BaseLPManager`, so
`StableLPManager` inherits them too.

## Code changes (`src/`)

1. **`BaseLPManager.sol`** — add `import IPriceOracle`, `address public priceOracle`, `PriceOracleSet`
   event, the two `OperatorSwap*` errors, `setPriceOracle` (`onlyOwnerNFT`), `_isOwnerCall`, `_guardSwap`
   (owner ⇒ free; operator ⇒ oracle must vouch, fail-closed). Identical semantics to task_031.
2. **`VolatileLPManager.sol`** — remove the now-inherited members (import, field, event, errors,
   `setPriceOracle`, `_isOwnerCall`, `_guardSwap`); the `_guardSwap(byOwner, …)` call sites are unchanged
   (resolve to the base).
3. **`StableLPManager.sol`** — thread `byOwner = _isOwnerCall()` into the `OP_ALLOCATE` (covers
   `allocate` + `allocateFrom`) and `OP_REINVEST` payloads; decode it in `_handleAllocate` /
   `_handleReinvest`; call `_guardSwap(byOwner, …)` after the `allocate` pre-swap (`_allocateLeg`) and the
   `reinvest` swap (`_handleReinvest` — now capturing the swap delta it previously discarded).

## Notes
- Storage: appending `priceOracle` to the base only affects **new** implementation deployments; existing
  EIP-1167 clones delegatecall their fixed old impl and are unaffected (clones are not upgradeable).
- EIP-170: `StableLPManager` gains the guard + threading; verify it stays < 24,576 B (`forge build
  --sizes`). If tight, the guard is small; no library split expected.

## Tests
- `test/StableLPManagerOperatorSwapGuard.t.sol` — operator `allocate`/`reinvest` swap: reverts without an
  oracle / on a non-enforcing oracle / on an out-of-bounds oracle; succeeds on an in-bounds oracle; owner
  bypasses; swapless operator `allocate` unaffected.
- Existing Volatile guard tests must stay green (guard now inherited from base).

## Verification
```bash
forge fmt --check
forge build --sizes
forge test -vvv
```
</content>
