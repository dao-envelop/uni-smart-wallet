# Security Audit — StableLPManager (Uniswap V4) — asset/fee-loss focus

**Scope:** `src/StableLPManager.sol`, `src/abstract/V4PositionManager.sol`,
`src/abstract/SingletonNFTOwned.sol`, `src/StableLPFactory.sol`, `src/FeeRedeemer.sol`,
`src/lib/PositionMath.sol`.
**Focus (by request):** **Critical & High only** — places where capital or **accrued-but-unclaimed
fees** can be lost or stuck. Not a full-surface re-audit.
**Method:** manual trace of V4 delta accounting (settle/take/skim) at every point funds move, two
parallel exploration passes (asset-flow map; real on-chain logs), cross-checked against the live
Unichain-mainnet (chainId 130) transaction log in `stablelp-ui/tasks/ui-mode-test-report.en.md`
(~30 real tx). Builds on the prior audits (`audits/2026-05-17`, `audits/2026-06-23`).

**Verdict:** **No new externally-exploitable Critical fund-drain** — concurs with the prior audits.
Principal is never taxed by the protocol fee; all deltas net via `_settleManaged` (no orphaned
`CurrencyNotSettled`); realized fees are always returned (90%) to the holder or compounded — there is
no path that forfeits accrued fees other than the intended 10% skim and dust rounding. The material
**High**-severity asset-loss surface reduces to **two** items, both conditional on trust/config rather
than an external attacker. Both are reproduced by passing PoC tests (see Verification).

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| H-1 | **HIGH** (cond.: malicious/compromised operator) | The pre-swap in `allocate`/`allocateFrom`/`reinvest` (`onlyAuthorized` — operator **or** owner) is bounded **only by the operator-supplied** `sqrtPriceLimitX96`. A hostile operator passes a maximally-wide limit and routes the manager's capital through an adverse in-pool swap that a confederate sandwiches → value extracted to the operator's counterparty, economically defeating the "operators cannot move capital out" invariant (`spec_StableLPManager.md:74`). | **OPEN** — prior audits rated this MEDIUM ("operator must set a tight limit"), but that is not a mitigation against the operator *itself* |
| H-2 | **HIGH** (cond.: non-standard managed token) | V4 settle / `withdrawTo` delivery accounting assumes `received == sent`. A fee-on-transfer / rebasing managed stable breaks `_settle` (under-pays PoolManager → `CurrencyNotSettled` revert → exit path DoS / locked principal) and the `withdrawTo` delivery via `_take` (recipient silently gets `amount - fee`). No on-chain guard in `initialize`. | **OPEN** — prior audits rated this LOW/INFO ("managed currencies must be standard ERC-20", doc-only) |

> Re-rating note: under the **asset-loss lens** both outcomes are material (capital extracted; principal
> locked), hence HIGH. Both are *conditional* (hostile operator / non-standard token configured), not
> unconditional external drains. If the trust model treats the operator as fully trusted and the stable
> set as curated off-chain, both fall back to "accepted/documented" and the residual Critical/High risk
> in the deployed code is **nil**.

## H-1 — operator value extraction via unconstrained pre-swaps

**Where:** `StableLPManager._allocateLeg` (`src/StableLPManager.sol:313-322`), `_handleReinvest`
(`:475-477`), shared primitive `V4PositionManager._swap` (`:378-386`). Entry points
`allocate`/`allocateFrom`/`reinvest` carry `onlyAuthorized` (`src/StableLPManager.sol:255,265,456`).

**Mechanism:** the only check on a pre-swap is that the input was fully consumed
(`src/StableLPManager.sol:319`); there is **no minimum-output** and the price bound is the
operator-chosen `swapPriceLimit`. A hostile operator passes `MIN/MAX_SQRT_PRICE`, swaps the manager's
balance through the pool at a skewed price, and a separately-funded confederate sandwiches it. With no
aggregate cap on auto-`allocate`, the cycle repeats. The "volume engine" pattern in the real log
(`ui-mode-test-report.en.md:75-76`, Manager #2 driving `allocateFrom`↔`withdraw` swap cycles) is
exactly this primitive used benignly.

**Impact:** the invariant holds *literally* (no direct `take` to the operator) but is *economically*
bypassed — the holder's capital is bled to the operator's counterparty.

**Recommendation (preferred → fallback):**
- **Contract-enforced swap price-deviation clamp:** before `_swap`, read `getSlot0(poolId)` and reject/
  clamp any `sqrtPriceLimitX96` farther than a tight band (stables, e.g. ±0.5–1%) from the live price.
  Removes the operator's ability to weaken the bound while keeping autonomy. (Mind EIP-170 — ~177 B
  margin; put the helper in the linked `PositionMath` library.)
- Alternatives: make the pre-swap **owner-only**, or add a per-swap / aggregate notional cap.

## H-2 — fee-on-transfer / rebasing managed token breaks accounting

**Where:** `_settle` (`src/abstract/V4PositionManager.sol:392-401`, transfers exactly `amount`),
`allocateFrom` snapshot guard (`src/StableLPManager.sol:276-289`), `withdrawTo` delivery `_take`
(`:399`), managed-stable registration in `initialize` (`:173-184`, no token-property check).

**Mechanism:**
- **Settle side (FoT):** `_settle` does `currency.transfer(PM, amount)` then `settle()`; PoolManager
  receives `amount - fee` → `CurrencyNotSettled` → the whole unlock reverts. If such a token is a leg
  of a position, `withdrawTo`/`allocate` paths that owe it begin reverting → **principal locked** (same
  class as the fixed treasury-blocklist HIGH, but via a token property rather than an address).
- **Take side:** the manager records `owed` but receives/delivers `owed - fee` → **silent leak**; the
  `withdrawTo` `got >= amount` guard reads the V4 internal delta (full `amount`), so delivery succeeds
  while the recipient is short-changed.
- **`allocateFrom` snapshot guard:** a rebase between snapshot and post-check yields false
  `UnexpectedStableSpend` reverts or misses a real overspend.

Deployment stables (USDC, USD₮0) are neither FoT nor rebasing, so **current prod is safe**. The risk
activates only if a non-standard token is configured (USDT has a *disabled* but configurable transfer
fee; some "stables" rebase). There is no on-chain detection — the pool is chosen at `initialize`.

**Recommendation:** keep the hard invariant (already documented in `task_016`) **and** enforce it
off-chain — a curated stablecoin allowlist at the factory/UI that refuses to assemble a manager on a
FoT/rebasing token. Optional robustness (costly under EIP-170, and no help against rebasing):
balance-delta-measured settle/delivery instead of nominal amounts.

## Confirmed correct (re-verified, no Critical/High)

- Protocol fee skimmed **only** from realized fees (`_skimFee`, `src/StableLPManager.sol:564-571`);
  `cut ≤ fee` always (ceil; `fee=1 → cut=1`). Principal never taxed.
- No accrued-fee forfeiture: every liquidity removal (`_pullLiquidity`), `poke` (`_handleClaim`),
  `reinvest`, and top-up (`_addLiquidity`) realizes `feesAccrued` and returns 90% to holder/position;
  no path removes liquidity without collecting fees.
- `withdrawTo` leaves no stranded funds: after `_take(amount)`, residuals net via `_settleManaged`
  across the full managed-stable union; failure is a safe revert (`AmountNotDelivered`), not a leak.
  The "haircut" bug (`fix/withdraw-haircut` → `AmountNotDelivered`) was **UI swap-sizing**, fixed and
  confirmed on-chain (`ui-mode-test-report.en.md:58`).
- ERC-6909 fee skim + `FeeRedeemer`: claims accrue to the treasury, redeemed via `unlock→burn→take`;
  the deploy wires `FeeRedeemer` (not an EOA) as `PROTOCOL_TREASURY`, so fees are not stranded.
- Reentrancy: all external entry points `nonReentrant`; `unlockCallback` gated to `POOL_MANAGER`.
- Singleton-NFT / operators: mint-once, no-burn, operator auto-clear on transfer, splice-on-disable.
- Clone init: impl locked (`_initialized=true` in constructor); `createManager` is atomic clone+
  `initialize` (`StableLPFactory:32-38`) — no `initialize` front-run window.
- `salt == poolId`, O(1) registry splice, native-ETH settle/take — correct.

LOW/INFO (out of the requested scope): ceil skim over-charges dust fees (`fee=3 → cut=1`, 33% vs 10% —
`ui-mode-test-report.en.md:73`); stray native ETH with no native pool sits until
`executeEncodedTxBatch`; no swap deadlines; `reinvestRemainder` is a no-op; `reinvest` is not wired
into the UI (feature gap, not security).

## Verification (PoC tests)

PoC tests added under `test/` (no contract change; a `MockFeeOnTransferERC20` helper was added to
`test/helpers/Mocks.sol`). Run:

```bash
forge test --match-path "test/StableLPManagerH*PoC.t.sol" -vv
```

**H-1** — `test/StableLPManagerH1OperatorExtractionPoC.t.sol`:
- `test_H1_baseline_pureSandwich_attackerLoses` — a pure round-trip sandwich on a static pool **loses**
  (double pool fee), so any profit below is sourced from the victim.
- `test_H1_operatorWideLimitSwap_extractsValueToAttacker` — operator's wide-limit `allocate` swap lets
  the confederate net **≈128,950e18 (~$128k)** out of the manager.
- `test_H1_tightLimit_wouldHaveReverted` — a tight limit reverts the adverse swap (protection exists
  but is operator-chosen).

**H-2** — `test/StableLPManagerH2FeeOnTransferPoC.t.sol` (open a position at `feeBps==0`, then flip the
fee on):
- `test_H2_withdrawTo_silentlyUnderDelivers` — `withdrawTo` does **not** revert but delivers
  **4,950 vs 5,000 requested** (1% silently lost).
- `test_H2_allocate_revertsOnSettleShortfall` — re-allocating the fee-bearing stable reverts
  (`CurrencyNotSettled`) → exit/redeploy DoS.

Full regression: `forge fmt --check && forge build --sizes && forge test` — 158 pass, 2 fork skipped
without `BASE_RPC`.

## Remediation status

Both H-1 and H-2 are **OPEN** (no code change applied — PoC only). H-1 fix is a contract change
(price-deviation clamp); H-2 fix is primarily an off-chain allowlist plus the existing documented
invariant. Decide per the accepted operator/token trust model.
