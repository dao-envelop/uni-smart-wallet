# Security Audit: StableLPManager and dependencies

**Date:** 2026-07-02
**Project:** `uniswap-smart-wallet` (Envelop V2 / UniSmartWallet)
**Revision:** branch `master`, commit `c9cd708`
**Focus:** LOSS OF FUNDS ONLY — leakage of capital or accrued fees, silent under-delivery, protocol fee paid out of principal, locked/bricked funds (exit DoS), accounting errors that misvalue or misroute value.

---

## 1. Scope

Audited contracts:

| File | Purpose |
|---|---|
| `src/StableLPManager.sol` | Primary target — NFT-owned singleton (TOKEN_ID=1), EIP-1167 clone, positions keyed `salt == poolId`, hookless pools only, 10% protocol fee as ERC-6909 claims to an immutable treasury |
| `src/StableLPFactory.sol` | EIP-1167 clone factory (CREATE2, atomic `initialize`) |
| `src/abstract/V4PositionManager.sol` | V4 base layer: unlock dispatcher, position registry, swap/settle/take, `_settle`/`_take`/`_takeClaim` primitives |
| `src/abstract/SingletonNFTOwned.sol` | Singleton-NFT authorization + operators |
| `src/lib/PositionMath.sol` | Tick snapping, `requireValidTickRange`, `liquidityFromAmounts` |
| `src/lib/PositionState.sol` | View-only position valuation (principal + fees) for metadata |
| `src/FeeRedeemer.sol` | Redemption of the protocol-fee ERC-6909 claims (`unlock → burn → take`) |

**Threat model.** External attackers cannot call value functions (all gated behind `onlyOwnerNFT` / `onlyAuthorized`; `unlockCallback` behind `msg.sender == POOL_MANAGER`). Realistic actors:
(a) a malicious/compromised operator (`onlyAuthorized`);
(b) token behavior (fee-on-transfer / rebasing);
(c) pure accounting/rounding bugs that leak regardless of actor.
The owner harming themselves is **not** a finding.

---

## 2. Methodology

A multi-agent pipeline was used:

1. **Fan-out.** The surface was split into domains (fee-accounting, reinvest-sizing, withdraw-netting, registry/factory, native/reentrancy, operator/token-highs, verify-B-fixes); each domain was covered by an independent auditor agent reading the source directly (not from memory).
2. **Adversarial verification.** Every candidate was run through three independent skeptic-verifiers; a candidate reaches the report only with ≥2 of 3 "real" votes (genuinely exploitable and causing loss of funds within the threat model).
3. **Lead synthesis.** Surviving findings were consolidated, ranked by severity, and each HIGH given a patch sketch with an EIP-170 cost estimate.

Total: 7 domain finder agents + 10 verifier agents + lead synthesis (17 agents). The clone's EIP-170 runtime-bytecode margin (**≈177 bytes**) was accounted for.

---

## 3. Result: NO findings survived verification

**No candidate passed the verification threshold (≥2/3).** The confirmed-findings set is empty. Below is what was checked and why the loss-of-funds surface is clean; §5 covers the dismissed candidates (including the two prior OPEN HIGHs), §6 re-confirms the audit-B fixes, §7 is an info note.

### What was checked and why it is clean

**Protocol fee vs principal (`_skimFee`, `_skimFees`, L623–637).**
The fee is drawn exclusively from `feesAccrued` — the second return of `modifyLiquidity`, which in v4-core holds only accrued fee deltas, never principal. At every call site (`_addLiquidity` L400, `_pullLiquidity` L478, `_handleClaim` L505, `_handleReinvest` L533) `_skimFees` receives `fees`, not `delta`. Principal is never taxed. The cut rounds UP (`(_pos(fee) * BPS + 9_999) / 10_000`), in the protocol's favor; no overflow (`_pos(fee) ≤ uint128 max`). The skim goes through `_takeClaim` (ERC-6909), so a blocklist/pause on the treasury cannot revert the unlock and lock principal. No principal-to-fee leakage.

**Exit path / DoS (`withdrawTo`, `_handleWithdrawTo`, `_pullLiquidity`).**
The `got < int256(p.amount)` guard (L451–452) checks the credit delta BEFORE delivery, `_take` delivers exactly `p.amount` straight to the recipient, and residuals net back via `_settleManaged`. For standard (non-FoT) tokens there is no under-delivery/misvaluation. The `s.liquidityToPull > have` pre-check (L430) prevents pulling more than exists.

**Registry accounting (`_addLiquidity`, `_pullLiquidity`, `_registerSalt`/`_removeSalt`).**
`salt == poolId`, O(1) splice via `_saltIndexPlusOne`. When liquidity drops to zero the entry is deleted (`_pullLiquidity` L480–483). Merging into an existing position (`positions[salt].liquidity += L`) is correct. No double registration of a salt (the `if (positions[salt].liquidity == 0)` branch).

**Authorization.** `withdrawTo`/`executeEncodedTxBatch`/`setOperator`/`setPositionDescriptor` are `onlyOwnerNFT`; `allocate`/`allocateFrom`/`reinvest`/`claimFees` are `onlyAuthorized`. Operators cannot reach any capital-draining function. `_clearOperators` resets delegations on NFT transfer; the list is compact (splice-on-disable), so a transfer-time gas bomb is impossible.

**`allocateFrom` snapshot guard (L330–343).** The pre-snapshot of all managed-stable balances plus the post-check "only `stable` may decrease" correctly prevents dipping into previously-deposited funds during deposit-and-allocate.

**Reentrancy.** All external value functions (`allocate`/`allocateFrom`/`withdrawTo`/`reinvest`/`claimFees`) are `nonReentrant`. `executeEncodedTxBatch` is unguarded but `onlyOwnerNFT` (documented as accepted).

**`FeeRedeemer`.** `unlock → burn(own claims) → take` nets the delta to zero; `redeem` is `onlyOwner`; zero balances are skipped. No leakage.

---

## 4. HIGH findings

None. No patch sketches with EIP-170 estimates are required.

---

## 5. Considered & dismissed

### 5.1. C-H1 — Operator sandwich via pre-swap bounded only by `sqrtPriceLimitX96` (no min-out/oracle)
**Claimed severity:** HIGH · **REASSESS_PRIOR** (prior OPEN HIGH) · **Status: not confirmed as NEW, remains previously accepted**
**Location:** `src/StableLPManager.sol:370` (`_allocateLeg`), L535–536 (`_handleReinvest`).

The pre-swap in `allocate`/`reinvest` is indeed bounded only by the operator-supplied `swapPriceLimit`/`sqrtPriceLimitX96`, with no min-out and no external oracle. The verifiers did not confirm this as a **new** finding: it is exactly the previously documented and **accepted** model element (the operator is trusted within `onlyAuthorized`; auto-allocate has no aggregate cap — accepted). Funds are not routed out of the contract: the swap happens inside the same pool, not to an arbitrary address; the damage is only price slippage inside an operator-trusted action. The bar of "new loss of funds outside the already-accepted model" is not met. Severity reassessment did not change the verdict: it stays OPEN/ACCEPTED in its prior form, not reopened by this report.
**Recommendation (no status change):** if operator trust is ever weakened — add a `minAmountOut` on the pre-swap or a TWAP guard; for now this is deliberately out of scope.

### 5.2. C-H2 — No fee-on-transfer/rebasing guard: an FoT token breaks `_settle` (exit DoS) and silently under-delivers in `withdrawTo`
**Claimed severity:** HIGH · **REASSESS_PRIOR** (prior OPEN HIGH) · **Status: not confirmed as NEW, remains previously accepted**
**Location:** `src/abstract/V4PositionManager.sol:466` (`_settle`), L483–485 (`_take`).

An FoT/rebasing managed token can indeed break `_settle` (underpay the PoolManager → `CurrencyNotSettled` → unlock revert) and under-deliver in `_take`. The verifiers did not count it as new: the pool set is fixed by the owner in `initialize`, and managed-stables are owner-supplied config; adding an FoT token to the config falls under "owner harming themselves" (not a finding) or the previously accepted item "no FoT guard in `initialize`". Operators cannot add a pool. The bar of a realistic untrusted actor is not met. Severity reassessment did not change the verdict: it stays accepted/documented.
**Recommendation (no status change):** if needed — an allow-list of vetted stables at the factory level; on-chain FoT detection is bytecode-expensive and not justified here, since the config is owner-trusted.

### 5.3. INFO — `reinvest`/`allocate` with `minLiquidity == 0` on a drained pool creates a zero-liquidity ghost entry in `openSalts`
**Severity:** INFO · **NEW** · **Status: not confirmed (not a loss of funds)**
**Location:** `src/StableLPManager.sol:402` (`_addLiquidity`, the `positions[salt].liquidity == 0` branch).

If an add (`reinvest`/`allocate`) is called for a pool whose position was previously fully withdrawn and the resulting `L == 0` (no fees / insufficient amounts) while `minLiq == 0`, the `if (L < minLiq)` guard (0 < 0 == false) at L391 does not fire, `modifyLiquidity(0)` succeeds, and `_registerSalt` creates a `liquidity: 0` entry, leaving a ghost element in `openSalts` (repeated calls overwrite `_saltIndexPlusOne`). All three verifiers confirmed the behavior as real but unanimously dismissed it as a loss of funds: principal matches the actually-added liquidity (zero), and only enumeration/metadata (view) is affected. Out of the loss-of-funds focus.
**Recommendation:** cosmetically — an early return on `L == 0` in `_addLiquidity`; no capital risk.

---

## 6. Re-confirmation of audit-B fixes (holding)

All four audit-B fixes were re-verified and **hold**:

- **B-1 · ERC-6909 skim (treasury blocklist cannot brick the unlock).** Confirmed: `_skimFee` → `_takeClaim` → `currency.take(..., true)` (V4PositionManager L493–495). The skim is a `mint` of ERC-6909 claims, not an ERC-20 transfer; a pause/blocklist on `PROTOCOL_TREASURY` is not in the path and cannot revert the unlock / lock principal. `FeeRedeemer` redeems the claims separately.
- **B-2 · splice-on-disable of the operator list.** Confirmed: `SingletonNFTOwned.setOperator` calls `_spliceOperator` on disable (swap-and-pop, L90–102); `_operatorList` holds only active operators, `_clearOperators` (L124–133) is bounded by the live operator count — no transfer-time gas bomb.
- **B-3 · protocol fee rounding UP.** Confirmed: `_skimFee` L633 — `(_pos(fee) * PROTOCOL_FEE_BPS + 9_999) / 10_000`, ceil in the protocol's favor, no sub-threshold zero-skim leak, overflow excluded.
- **B-4 · uninitialized-pool guard in `_addLiquidity`.** Confirmed: L387–388 — `(uint160 sqrtP,,,) = getSlot0(id); if (sqrtP == 0) revert PoolUninitialized();`. An analogous guard exists in the base layer's `_openPosition` (L202–203).

---

## 7. INFO: doc/code mismatch on `ORACLE_TYPE`

**Location:** `src/StableLPManager.sol:41` vs comments L40, L132.

The code declares `uint256 public constant ORACLE_TYPE = 3000;` (L41), while doc comments in two places claim `2002`:

- L40: `/// ... for oracle indexing (constant 2002).`
- L132: `/// @param oracleType The Envelop oracle type tag (ORACLE_TYPE = 2002).`

The `EnvelopV2OracleType(ORACLE_TYPE, "StableLPManager")` event (L224) is emitted with **3000**, not 2002. This is not a loss of funds.

The canonical value is **3000** (the constant and the emitted event are correct); the erroneous part is the L40/L132 comments (`2002`). They should be brought to `3000` at the next edit of the file. The code (`ORACLE_TYPE = 3000`, L41) does **not** need to change. No edit was made as part of this audit — only recorded.

---

## 8. Conclusion

Within the loss-of-funds focus, there are no confirmed findings. The protocol fee is strictly isolated from principal and taken via ERC-6909 claims; the exit path is guarded by a credit-delta pre-check and is not DoS-prone for standard tokens; authorization and operator clearing are correct; the `allocateFrom` snapshot guard prevents dipping into previously-deposited funds; the audit-B fixes hold. Both prior OPEN HIGHs (C-H1 sandwich, C-H2 FoT) remain in the status of previously-accepted threat-model elements (trusted operator; owner-configured pools) and are not reopened. The only action item is the info-level `ORACLE_TYPE` mismatch (§7), which carries no capital risk.
