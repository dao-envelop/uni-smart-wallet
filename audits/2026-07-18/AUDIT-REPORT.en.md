# Security Audit: VolatileLPManager & post-v1.0.0 refactor (previously-unaudited surface)

**Date:** 2026-07-18
**Project:** `uniswap-smart-wallet` (Envelop V2 / UniSmartWallet)
**Revision:** branch `master`, commit `84a36b2`
**Focus:** Loss of funds / unauthorized withdrawal / **operator-compromise risk**.

---

## 1. Why this audit exists

The four prior audits (`audits/2026-05-17`, `06-23`, `06-29`, `07-02`) and release **v1.0.0
(2026-06-29)** covered **only `StableLPManager`** (see scope tables; the words *Volatile* and
*recenter* appear in **none** of the prior reports). Everything in the CHANGELOG `[Unreleased]` section is
**post-audit and never reviewed**:

- **`VolatileLPManager`** (task_026) — multi-position, per-call ranges, **`recenter`**, `IPriceOracle`.
- **`BaseLPManager` split** (task_028) — the monolithic Stable manager was refactored into a shared base.
- **Unified `withdrawTo`** into the base (task_029).
- **Universal `LPManagerFactory`** (task_030) — replaced `StableLPFactory`.

This audit targets exactly that unaudited surface.

### Threat model (unchanged from `2026-07-02`)
External callers cannot reach value functions (`onlyOwnerNFT` / `onlyAuthorized`; `unlockCallback`
behind `msg.sender == POOL_MANAGER`). Realistic actors: **(a) a compromised operator** (`onlyAuthorized`
= owner **or** operator: `allocate` / `allocateFrom` / `reinvest` / `claimFees` / **`recenter`**);
(b) token behaviour (fee-on-transfer / rebasing); (c) pure accounting bugs. **The owner harming itself is
not a finding.**

## 2. Methodology

Replicates the `2026-07-02` multi-agent pipeline. **5 independent finder agents** (read-only, reading the
source directly) across domains: recenter/principal, multi-position registry, factory/clone, base-refactor
settlement, oracle/native/reentrancy. The one severity-driving candidate was then run through **2
independent adversarial verifiers** each tasked to *refute* it; a finding is reported only at **≥2/3**
"real & loss-of-funds". The v4-core `modifyLiquidity`/`unlock` settlement semantics were verified against
the vendored `lib/v4-hooks-public/lib/v4-core/src/PoolManager.sol`.

## 3. Result

| ID | Severity | Status | Title |
|---|---|---|---|
| **H-VOL-1** | **HIGH** | **CONFIRMED 3/3** | Compromised operator extracts position **principal** via `recenter` |
| **M-VOL-2** | **MEDIUM** | Confirmed (root cause / enabler) | No mandatory non-operator swap slippage floor; oracle off-by-default & fail-open |
| L-FAC-1 | LOW | Confirmed | Factory CREATE2 salt omits `initData` → counterfactual-funding config-substitution front-run (funds recoverable) |
| L-REG-1 | LOW | Confirmed | Ghost / duplicate `openSalts` entries (`L==0` adds; `recenter` zero-L) — off-chain/UI only |
| L-TOK-1 | LOW | Reaffirmed (accepted) | Fee-on-transfer / rebasing managed token breaks `_settle`/`withdrawTo` (prior C-H2) |
| I-DOC-1 | INFO | — | Stale docs: `WITHDRAW_TO_V=9` (code reuses `OP_WITHDRAW_TO=5`); `ORACLE_TYPE` comment mismatch |

**Operator-compromise verdict.** A compromised operator **cannot** directly transfer funds out
(`withdrawTo`, `executeEncodedTxBatch` are `onlyOwnerNFT`; auth separation and `_clearOperators`-on-
transfer are correct). But it **can economically extract value via swaps whose slippage bounds it fully
controls**. For **StableLPManager** this is bounded to **idle balances + fees** (the accepted C-H1). For
**VolatileLPManager** the new `recenter` op removes a position's **principal** before that operator-
parameterized swap, so a compromised operator can bleed **principal too** — a genuine escalation, on code
no prior audit reviewed. The literal invariant "operators can never move capital out" holds; the economic
one does not.

---

## 4. HIGH

### H-VOL-1 — Compromised operator extracts position principal via `recenter`
**Severity: HIGH · CONFIRMED by finder + 2/2 adversarial verifiers (3/3).**
**Location:** `src/VolatileLPManager.sol:292` (`recenter`, `onlyAuthorized`), `:298-344` (`_handleRecenter`),
`:347-354` (`_rebalanceSwap`), `:264-286` (`_addLiquidityAt`), `:357-360` (`_posDelta`); settlement
`src/BaseLPManager.sol:472-486`; swap primitive `src/abstract/V4PositionManager.sol:162-170`.

**Mechanism.**
1. `recenter` is operator-callable (`onlyAuthorized`). It removes the **entire** position:
   `modifyLiquidity(liquidityDelta = -pos.liquidity)` (`:305-314`). In v4-core,
   `callerDelta = principalDelta + feesAccrued` is booked to the manager's transient account
   (`_accountPoolBalanceDelta`, `PoolManager.sol`). `_skimFees` claims only the protocol cut of the *fee*
   component, so **the full principal remains as a positive `currencyDelta`** — spendable inside the same
   unlock. Pools are hookless, so no hook can alter the delta.
2. `_rebalanceSwap` then swaps with **operator-supplied** `swapAmountIn`, `swapPriceLimit`, `minAmountOut`
   (`RecenterParams`). The swap nets against that same account, so **the freed principal funds the swap
   input**. Setting `minAmountOut = 0` and `swapPriceLimit` to the MIN/MAX-sqrt extreme disables both
   Uniswap guards; the full-fill check (`:350`) is not a slippage floor. If `swapAmountIn` exceeds freed
   principal, the shortfall is `_settle`d from the manager's **idle balance** (`_settleCurrency`,
   `:479-486`) — idle is drainable too.
3. Re-add is sized from `_posDelta` (positive leftover) with operator `minLiquidity = 0` and operator-
   chosen `newTickLower/newTickUpper`, so it can mint `L ≈ 0`; the diminished residual returns to the
   manager via `_settleManaged`.
4. **The only protocol-level guard** is `_guardSwap → IPriceOracle.check`, a **no-op when `priceOracle ==
   address(0)` (the default)** and **fail-open** even when set (returns without reverting on no reference).

**Exploitation (single searcher contract holding an operator delegation):** front-run the configured pool
to skew price → call `recenter{swapAmountIn ≈ freed principal (+idle), minAmountOut:0, minLiquidity:0,
swapPriceLimit: extreme}` (the manager dumps principal at a ruinous rate) → back-run to capture it.
`nonReentrant` does not help — the sandwich legs are separate unlocks, not re-entries. Alternatively the
operator is simply the counterparty LP in a thin pool.

**Impact.** Per call: ~the input-side principal of the recentered position + idle balance of that
currency; repeatable over every position and both directions ⇒ whole-portfolio principal drainable.
Extractable fraction bounded by pool depth (≈100% in a thin/JIT pool). **Precondition:** operator
delegation + ≥1 open position + `priceOracle` unset (default) or stale/permissive.

**This is not the accepted C-H1.** Stable's `onlyAuthorized` paths never remove principal
(`allocate`/`allocateFrom` add; `reinvest`/`claimFees` use `liquidityDelta:0` and swap only realized
fees); the only principal-removal path there, `withdrawTo`, is `onlyOwnerNFT`. `recenter` is the **first
operator-callable principal-removal path**, so it escalates C-H1 from idle/fees to principal.

**Remediation (options; decision deferred by request):**
- Enforce a **non-operator** slippage floor: make a strict, always-fresh `IPriceOracle` **mandatory** for
  volatile swaps and **remove fail-open** where an oracle is set; or derive a `minAmountOut` from a v4
  pool TWAP inside the contract rather than trusting the operator; or
- add a **value-conservation post-check** to `recenter` (position value after ≥ X% of value before, via
  `PositionState`); or
- as a quick minimal fix, move **`recenter` to `onlyOwnerNFT`** (removes the operator principal path
  entirely; operator loses fast recentering).
- Suggested reproduction: a `recenter`-based PoC mirroring `test/StableLPManagerH1OperatorExtractionPoC`,
  asserting attacker profit > 0 and manager principal loss.

---

## 5. MEDIUM

### M-VOL-2 — No mandatory non-operator swap-slippage floor (oracle off-by-default & fail-open)
**Severity: MEDIUM (standalone) / root-cause of H-VOL-1.**
**Location:** `src/VolatileLPManager.sol:40` (`priceOracle` default zero), `:146-151` (`_guardSwap`),
`:218-230` (`_allocateLegV`), `:347-354` (`_rebalanceSwap`); `src/StableLPManager.sol:180-185`
(`_allocateLeg`), `:280-282` (`_handleReinvest` — swap result **fully ignored**);
`src/interfaces/IPriceOracle.sol` (fail-open by contract).

Every swap bound (`minAmountOut`, `minLiquidity`, `swapPriceLimit`) is **operator-supplied**, so it
defends an honest operator against market slippage but gives **zero** protection against a malicious one.
The sole non-operator bound is `IPriceOracle`, which is (a) `address(0)` by default, (b) owner-only to
set, and (c) fail-open even when set. Consequently a compromised operator can bleed **idle + fees**
through `allocate`/`reinvest` on **both products** (Stable `reinvest`'s swap is the weakest — no output or
full-fill check at all), and **principal** through `recenter` (H-VOL-1). Recommend a mandatory,
contract-enforced floor as in §4. Document, at minimum, that a strict oracle is **operationally required**
in production.

---

## 6. LOW / INFO

### L-FAC-1 — Factory CREATE2 salt omits `initData`
`src/LPManagerFactory.sol:96` — `salt = keccak256(abi.encode(expectedOwner, implementation, n))`.
`createManager` is permissionless and the predicted address depends only on
`(implementation, expectedOwner, nonce)`, not on `initData`. An attacker can front-run the advertised
counterfactual-funding flow (`predictManagerAddress` + pre-send) with a same-owner but attacker-chosen
`initData`, deploying at the victim's pre-funded address with attacker-chosen pools/descriptor. **Not
theft:** clone+`initialize` is atomic, the post-init `ownerOf(TOKEN_ID) == expectedOwner` check holds, the
singleton NFT still lands on the victim, and pre-sent funds are recoverable via the `onlyOwnerNFT`
`executeEncodedTxBatch` escape hatch. Griefing/mis-config only ⇒ LOW. **Fix:** bind the payload into the
salt — `keccak256(abi.encode(expectedOwner, implementation, n, keccak256(initData)))` — and mirror in
`predictManagerAddress`.

### L-REG-1 — Ghost / duplicate `openSalts` entries
`src/VolatileLPManager.sol:235-257`, `:264-286` (`L < minLiq` with `minLiq==0` passes on `L==0`), `:322-339`
(`recenter` may leave `liquidity==0` registered). An `L==0` add registers a zero-liquidity salt; re-
allocating a ghost salt even calls `_registerSalt` a second time, leaving a permanent orphan in
`openSalts`. **No on-chain fund path reads `openSalts`** — it is iterated only by the view aggregators
(`UniLens.sol:68`, `WalletPositionDescriptor.sol:83,204`), and liquidity accounting keys off
`_positions[salt]` directly, so no locked funds / no bricked owner exit. Off-chain/UI OOG griefing ⇒ LOW.
**Fix:** reject `L == 0` adds (`require(L > 0)` / `minLiquidity >= 1`).

### L-TOK-1 — Fee-on-transfer / rebasing managed token (prior C-H2, reaffirmed/accepted)
`src/abstract/V4PositionManager.sol:178` (`_settle`), `:195` (`_take`). An FoT/rebasing managed currency
breaks `received == sent`: `withdrawTo` silently under-delivers, `allocate` reverts on settle shortfall
(DoS on that stable). Accepted as owner-configured pools. Managed currencies **must be standard ERC-20**.
Optional: an allow-list of vetted stables at the factory/init layer.

### I-DOC-1 — Stale docs
`CLAUDE.md` mentions a volatile `WITHDRAW_TO_V=9`; the code reuses base `OP_WITHDRAW_TO=5` via `super`
(dispatch is correct — no op-code confusion). The `ORACLE_TYPE` comment mismatch noted in `2026-07-02` §7
persists. No capital risk.

---

## 7. Confirmed sound (no finding)

- **Protocol-fee isolation:** `_skimFees` receives only `feesAccrued` (2nd `modifyLiquidity` return) at all
  7 call sites — principal is never taxed; ceil-skim `(fee*1000+9999)/10000` never overflows/over-skims.
- **Net settlement:** `_settleManaged` over the deduped `managedStables` union settles each currency once
  against its aggregate delta; no unmanaged currency can enter an unlock ⇒ no `CurrencyNotSettled` DoS, no
  stranded credit.
- **Reentrancy:** ops are `nonReentrant`; `unlockCallback` is `msg.sender==POOL_MANAGER`; v4 reverts nested
  `unlock` and enforces net-zero deltas; `_guardSwap` is a `view` → **STATICCALL** (a malicious oracle can
  only revert). A callback/ERC777 pool token cannot re-enter an op, reach `unlockCallback`, or over-credit.
- **Native ETH:** `settle{value}` / `sync` / `receive()` accounting is exact and symmetric; no strand/leak.
- **Clone safety:** `POOL_MANAGER`/`PROTOCOL_TREASURY` immutables read via delegatecall; impl locked
  (`_initialized=true` in ctor); OZ v5.5.0 `ReentrancyGuard` checks `value==ENTERED`, so a fresh clone's
  `0` is not-entered — guard works without a constructor.
- **Factory core:** atomic clone+init, post-init owner check reverts (OZ `_requireOwned`) on a non-
  initializing call, re-init/mint-once invariants hold, allowlist can't be bypassed, Envelop events can't
  be spoofed by attacker bytecode.
- **Multi-position:** cross-pool salt aliasing is contained by `RangeMismatch` + V4 atomic rollback;
  `.poolId` is immutable after open; `withdrawTo` pre-check and pull read the same stored record.
- **Stable:** no operator-callable principal-removal path (confirmed).

---

## 8. Verification / reproduction

```bash
cd uniswap-smart-wallet && git submodule update --init --recursive
forge build --sizes            # StableLPManager < 24576 B (EIP-170 margin ~177 B — constrains Stable fixes)
forge test -vvv
forge test --match-path test/VolatileLPManagerAllocate.t.sol -vvv
BASE_RPC=... forge test --match-path "test/*.fork.t.sol" -vvv
# Recommended new PoC (H-VOL-1): recenter under a compromised operator, asserting attacker profit > 0
# and manager principal loss — mirror test/StableLPManagerH1OperatorExtractionPoC.t.sol.
```

## 9. Conclusion

The refactor (fee isolation, settlement, auth, reentrancy, clone safety) is **clean** — no regression that
leaks/strands/misroutes principal. The one new **HIGH** is **H-VOL-1**: `VolatileLPManager.recenter` lets a
compromised **operator** route a position's **principal** through a self-parameterized adverse swap and
extract it, because there is **no mandatory non-operator slippage floor** and the price oracle is off by
default and fail-open (M-VOL-2). This is a real escalation of the previously-accepted C-H1 onto code that
**no prior audit reviewed**. Before relying on the operator role for `VolatileLPManager` in production,
close H-VOL-1/M-VOL-2 (mandatory oracle / TWAP floor / value-conservation, or `recenter → onlyOwnerNFT`).
Lows are hardening (bind `initData` into the factory salt; reject `L==0` adds; enforce standard-ERC20).

*Method: 5 finder agents + 2 adversarial verifiers, read-only, no code changed in this pass.*
</content>
