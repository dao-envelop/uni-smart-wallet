# Security Audit: everything changed since the 2026-07-18 audit (v2.0.0 and post-release)

**Date:** 2026-09-04
**Project:** `uniswap-smart-wallet` (Envelop V2 / unisafe LP managers)
**Revision:** branch `master`, commit `359cefe`
**Focus:** loss of funds / unauthorized withdrawal / **operator compromise** (threat model unchanged, §1).

---

## 1. Scope and why

The last audit (`audits/2026-07-18`) reviewed commit `84a36b2`. Two blocks of `src/` changes landed since,
**neither of them reviewed**:

| Range | Tasks | What appeared |
|---|---|---|
| `84a36b2 → v2.0.0` | 031, 032, 033, 034, 035, 036, 039, 040, 041 | oracle gate on operator swaps (`_guardSwap`, `IPriceOracle.check → bool`), `ChainlinkPriceOracle` (+ L2 sequencer, heartbeat), factory salt binding `keccak(initData)`, zero-L add rejected, `UniLens`, descriptor |
| `v2.0.0 → 359cefe` | 042, 043, 044, 045, 047, 048, 051, 052 | `OpenVolatileLPManager` (hooks allowed), `moveLiquidity` (cross-pool in one unlock), `FeesCollected` on five paths, `operatorList`/`operatorCount`, `MAX_POOLS 8 → 32`, `rangeOf` public, `UniLens.oracleStatus/stableRanges/operators` |

The whole current `src/` (16 files, ~3.2k lines) was reviewed, with the listed changes as the focus.

**Threat model (unchanged).** External callers cannot reach value functions. Realistic actors:
**(a) a compromised operator** (`onlyAuthorized`: `allocate`/`allocateFrom`/`reinvest`/`claimFees`,
Volatile `recenter`/`moveLiquidity`); (b) token behaviour; (c) accounting bugs. The owner harming itself is
not a finding. For `OpenVolatileLPManager` the hook is trusted by construction (task_043) — findings there
are only about the completeness of the documented, accepted risk.

## 2. Methodology

1. Auditor skills refreshed (`ethskills` 1.1.0 and `uniswap-hooks` 1.6.0 both at latest; all six
   marketplaces updated); the `evm-audit-skills` master index and checklists loaded: general,
   precision-math, erc20, defi-amm (incl. Dacian CLM), oracles (Chainlink/Cyfrin/Sigma Prime),
   access-control, erc721, dos; plus Uniswap's `v4-security-foundations`.
2. Full read of `src/` and both diff ranges; v4 semantics checked against the vendored
   `lib/v4-hooks-public/lib/v4-core`.
3. The single HIGH candidate is **confirmed by an executable Foundry PoC**
   (`test/Audit20260904SwaplessDrainPoC.t.sol`, 2 tests, both green = the attack works) and
   **cross-checked against public incident databases** (§4). That is stronger evidence than the verifier
   vote of the previous report: there are numbers.
4. The recommended fix was **measured in bytes** (EIP-170 is the project's binding constraint).
5. Baseline: `forge build --sizes` (Stable 24,098 / Volatile 24,355 / Open 24,295 B), `forge test` —
   263 passed, 4 skipped (fork, no `BASE_RPC`); 265 passed with the PoC.

## 3. Result

| ID | Severity | Status | Title |
|---|---|---|---|
| **H-1** | **HIGH** | **REDUCED, NOT CLOSED** (task_053 + task_054; see [fix-review/FIX-REVIEW.en.md](fix-review/FIX-REVIEW.en.md)) | A compromised operator extracts principal **without any swap**: swapless `recenter`/`moveLiquidity` deploy liquidity at a skewed spot price; `moveLiquidity` lets it pick the thinnest configured pool |
| M-1 | MEDIUM | Confirmed | The shared `ChainlinkPriceOracle` is the single trust root of operator safety for every manager; its owner can instantly and boundlessly disable the guard (`maxDeviationBps ≤ 9999`, arbitrary aggregator) |
| L-1 | LOW | Confirmed | "owed ≤ desired by construction" is off by 1 wei (v4 rounds the add up); a swapless full-amount move/recenter with zero idle reverts |
| L-2 | LOW | Confirmed | `moveLiquidity` lacks the pre-checks `withdrawTo`/`recenter` have (unknown salt → `UnknownPool(0)`, over-pull → v4 panic) |
| L-3 | LOW | Confirmed | `ChainlinkPriceOracle`: no `minAnswer`/`maxAnswer` circuit-breaker check; single-step `Ownable` |
| L-4 | LOW | Confirmed | `OpenVolatileLPManager`: the accepted-risk list is incomplete — `afterAddLiquidityReturnDelta` (hook drains idle on every add) and the sign assumption in `_guardedSwap` are missing |
| I-1 | INFO | — | `FeesCollected` semantics changed (5 paths, gross): downstream must not read it as "delivered to balance" |
| I-2 | INFO | — | `operatorList` unbounded; `_clearOperators` on NFT transfer — self-inflicted gas DoS |
| I-3 | INFO | — | 4 fork tests skip without `BASE_RPC`; the new paths (move, fee events) have no live-v4 coverage |

> **Status, 2026-09-07.** The fix was audited in its own right —
> [`fix-review/FIX-REVIEW.en.md`](fix-review/FIX-REVIEW.en.md) — and then remediated in task_054.
> H-1 as reported no longer reproduces on the products that ship: the per-operation loss fell from
> 44.5 % to the accepted residual (`maxMidOffsetBps − poolFee`, ~9 bps at the shipped setting), an
> operator gets one authorized call per transaction, and `OpenVolatileLPManager` caps what a hooked add
> may bill. The review raised 15 issues of its own, two of them HIGH with working proofs of concept;
> those proofs are now regressions in [`fix-review/poc/`](fix-review/poc/).

**Operator-compromise verdict.** After task_031/032 an operator indeed cannot run an adverse **swap** inside
the manager. But task_031 recorded the premise "swapless operator ops … stay unrestricted — L is sized
from desired amounts, so owed ≤ desired and there is **no value-loss vector**". It is wrong. Bounding the
*amount* does not bound the *price* at which principal is deployed: the operator skews the spot price with
its own capital, deploys principal at it, and trades back through the manager's freshly concentrated
liquidity. PoC: **−22.4 %** of the portfolio in one `moveLiquidity`, **−44.5 %** in one `recenter`; the
oracle is never consulted. Same class as H-VOL-1, same precondition (operator compromised) — hence HIGH,
not CRITICAL.

---

## 4. HIGH

### H-1 — Swapless operator ops deploy principal at a manipulated spot price (sandwich on add)

**Severity: HIGH · CONFIRMED by executable PoC.**
**Location:**
`src/VolatileLPManager.sol:264-287` (`_addLiquidityAt` — reads `getSlot0`, never asks the oracle),
`:298-346` (`_handleRecenter`, step 3 ungated), `:371-398` (`moveLiquidity`/`_handleMove`),
`src/BaseLPManager.sol:351-359` (`_guardSwap` — reached only from swap paths).
Documented premise: `tasks/task_031_operator_swap_safety.md:14`.

**Mechanism.**
1. The operator (or a flash loan) skews the spot price of **any configured pool** with its own capital,
   without touching the manager. Cost: fees + slippage against *other* LPs' liquidity; in a thin pool,
   pennies.
2. The operator calls `recenter` (or `moveLiquidity` from a deep pool into that thin one) with
   `swapAmountIn == 0`, a narrow range at the skewed price and `minLiquidity = 0`. None of these paths
   reach `_guardSwap`: `_addLiquidityAt` sizes L from `getSlot0` and adds.
3. The operator trades the price back. The manager's liquidity, concentrated at the skewed price, *buys*
   the pumped token at the pumped price (or sells the cheap one — depends on the side). The difference
   goes to the attacker; the manager keeps an out-of-range position in the "wrong" token.
4. `moveLiquidity` (task_051) **widens the radius**: `recenter` used to be confined to the position's own
   pool (usually deep); now principal can be relocated into the thinnest pool of the owner-fixed set,
   where skewing is cheapest. The NatSpec on `moveLiquidity` ("degradation of yield, not theft — nothing
   leaves the manager") is literally true (no tokens are transferred) and economically false.

**PoC** (`test/Audit20260904SwaplessDrainPoC.t.sol`; no oracle set, no manager swap at all):

| Test | Scenario | Manager loss | Operator profit |
|---|---|---|---|
| `test_H1_..._swaplessMoveIntoSkewedPool` | 500/500 position in deep pool A (L=1e24); pool B thin (L=2e21); pump B to tick +6000 (+82 %); `moveLiquidity` everything into B at [5940, 6060]; dump back to tick 0 | **22.41 %** (1000e18 → 775.8e18) | +223.6e18 |
| `test_H1_..._swaplessRecenterAtSkewedPrice` | position in B; pump; `recenter` into the single-sided range [5880, 5940] below the price; dump | **44.49 %** | +444.3e18 |

Profit ≈ loss: extraction, not "degradation". The fraction is bounded by pool depth and the size of the
skew, and repeatable per position — as with H-VOL-1.

**Why this is neither the accepted C-H1 nor the closed H-VOL-1.** C-H1 (Stable) is bounded to idle+fees;
this is principal. H-VOL-1 was closed for *swaps*; here no swap is needed. Stable is affected within C-H1
(operator `allocate`/`reinvest` also add at spot without a gate, but only idle/fees).

**Cross-check against vulnerability databases.** Same pattern as:
- **Gamma Strategies, 2024-01-04, Arbitrum, ≈$4.6M** — Hypervisor deposit at a manipulated pool price;
  the deviation threshold was too wide ([Verichains](https://blog.verichains.io/p/gamma-protocol-exploit-analysis),
  [Neptune Mutual](https://neptunemutual.com/blog/how-was-gamma-protocol-exploited/)). Here there is no
  threshold at all.
- **Beefy CLM, Cyfrin (critical)** — `setPositionWidth`/`unpause` redeployed liquidity from `slot0`
  without the `onlyCalmPeriods` TWAP check: "attacker … forcing the protocol's liquidity to be deployed
  into an unfavorable range", then trade back ([Dacian, CLM Vulnerabilities](https://dacian.me/concentrated-liquidity-manager-vulnerabilities)).
- `evm-audit-defi-amm` checklist → "Drain protocol via sandwich attack on owner functions missing TWAP
  check" and "Slippage enforced on intermediate operation, not final amount"; Solodit category
  "Sandwich / price manipulation" ([Cyfrin, Solodit checklist #11](https://www.cyfrin.io/blog/solodit-checklist-explained-11-sandwich-attacks)).
Difference from the incidents: our trigger is a privileged operator, not any user — hence HIGH.

**Remediation (byte cost measured; sources reverted after measuring):**

| Option | What it does | Δ Volatile | Δ Open | Verdict |
|---|---|---|---|---|
| **A (recommended)** | In `_addLiquidityAt`, right after `getSlot0`: `_guardSwap(byOwner, key, true, 0, 0)`; `byOwner` threaded through `_addLiquidityV`/`_addLiquidityAt`. The oracle treats `amountIn == 0` as "check the pool's `getSlot0` spot against the reference, both directions". `IPriceOracle` **unchanged**; today's `ChainlinkPriceOracle.check` returns `false` on `amountIn == 0`, i.e. on the old oracle operator adds simply fail closed until the new one is deployed | **+24 B** (24,379; 197 left) | +24 B (257 left) | fits |
| B | New `checkSpot(key, sqrtPriceX96)` on `IPriceOracle` + `_guardSpot` in the base | +235 B (24,590; **−14 B**) | +235 B (46 left) | does not fit without trimming |
| C | `recenter`/`moveLiquidity` → `onlyOwnerNFT` | ≈0 | ≈0 | closes the vector at the product's expense (no fast bot recentering) |

Option A needs a new `ChainlinkPriceOracle` release (spot branch: `sqrtP² / 2^192` against
`answerIn/answerOut` with decimals, both sides within `maxDeviationBps`) and tests modelled on
`VolatileLPManagerOperatorSwapGuard.t.sol`. Residual risk after A — extraction within `maxDeviationBps`,
same as the swap gate. Clones are not upgradeable: the fix is a new implementation on the factory
allowlist plus migration; until then owners running bot operators should understand that operator
exposure today equals principal, bounded by the depth of the configured pools.

---

## 5. MEDIUM

### M-1 — Shared oracle: its owner can disable every manager's operator guard, unbounded and undelayed
**Location:** `src/oracle/ChainlinkPriceOracle.sol:85-98` (`setFeed`, `setMaxDeviationBps`),
`:111-115` (`_setMaxDeviation`: the only bound is `< 10_000`).

One (protocol-owned) oracle instance is wired into many managers via `setPriceOracle`. Its `Ownable`
owner can (a) raise `maxDeviationBps` to 9999 — the gate becomes a formality, (b) replace any currency's
aggregator with a contract returning whatever it likes. No timelock, no upper bound, no two-step
ownership. A compromise of "oracle key + operator key" drains principal across every manager at once,
while manager owners believe operators are "safe". The design is deliberate (protocol curates), but it is
a trust-model fact never stated to manager owners.
**Recommendation:** `Ownable2Step`; a constant upper bound on `maxDeviationBps` (e.g. ≤ 1_000); a
timelock or at least a dedicated event for `setFeed`/`setMaxDeviationBps` and a note in
`UniLens.oracleStatus` that the guard trusts the oracle owner; let a manager owner pin its own oracle.

## 6. LOW

### L-1 — "owed ≤ desired by construction" is off by 1 wei
**Location:** `src/VolatileLPManager.sol:259-262, 276`, `src/StableLPManager.sol:199-202, 216`.
`getLiquidityForAmounts` rounds L down, but v4 rounds the amounts owed for an add **up**
(`getAmount0Delta(…, roundUp=true)`), so owed can be `desired + 1` per side. Observed in the PoC's first
run: a `moveLiquidity` of the whole freed amount with zero idle reverts
`ERC20InsufficientBalance(mgr, 0, 1)`. Consequences: a swapless full move/recenter needs ≥ 1 wei idle per
side; `allocateFrom` can falsely revert `UnexpectedStableSpend` by 1 wei of another stable.
**Recommendation:** fix the comments; in `_handleRecenter`/`_handleMove` size from `freed − 1` or cover
the wei from idle explicitly; add an "idle = 0" test case.

### L-2 — `moveLiquidity` lacks the pre-checks its siblings have
**Location:** `src/VolatileLPManager.sol:371-383`. `withdrawTo` checks `UnknownPosition`/
`DeltaExceedsLiquidity`, `recenter` checks `UnknownPosition`; `moveLiquidity` only checks
`liquidity == 0`. An unknown `fromSalt` → `_indexOf(PoolId(0))` → `UnknownPool(0)`; an over-pull → an
arithmetic panic inside v4 / `_positions[..].liquidity -= liq`. No funds at risk, but a bot/UI gets an
unreadable reason and the "external entry validates, unlock executes" invariant is broken.
**Recommendation:** the same two checks as `withdrawTo` (≈30 B).

### L-3 — `ChainlinkPriceOracle`: no `minAnswer`/`maxAnswer`, single-step `Ownable`
**Location:** `src/oracle/ChainlinkPriceOracle.sol:148-162`. In a flash crash below `minAnswer` the feed
reports the floor instead of the real price (Venus/Blizz — LUNA); the oracle would then vouch for an
operator swap against a wrong reference, within the tolerance. Most modern feeds have the bounds
disabled, but the check is cheap: read `aggregator.minAnswer()/maxAnswer()` via `try` and treat an answer
at the bound as "no reference". `Ownable2Step` — see M-1.

### L-4 — `OpenVolatileLPManager`: the accepted-risk list is incomplete
**Location:** `src/OpenVolatileLPManager.sol:27-47`, `src/VolatileLPManager.sol:222-228`.
The list has (1) remove-delta, (2) brick, (3) swap-delta. Missing: **(4)** `AFTER_ADD_LIQUIDITY_RETURNS_DELTA`
— `_addLiquidityAt` ignores `callerDelta` and `_settleManaged` pays whatever the PoolManager says, so a
hook takes an arbitrary amount from idle on every add ("owed ≤ desired" does not hold for this product);
**(5)** in `_guardedSwap`, `uint256(uint128(-inDelta))` with a positive `inDelta` (a hook rebate larger
than the input) silently wraps to a huge number — the full-fill guard always passes. Both are inside "the
hook is trusted", but the owner choosing this implementation should see them in the same list.

## 7. INFO

- **I-1** `FeesCollected` is now emitted from `_skimFees` on all five paths and is always **gross**
  (before the 10 % skim). On reinvest/recenter/top-up the fee is compounded, not delivered to the
  balance. Indexers (stablelp-ui history, mcp-lp) must not read the event as "claimed to balance"; there
  is no net field — use `× 0.9` or `ProtocolFeeTaken`.
- **I-2** `operatorList` has no upper bound; `_clearOperators` on NFT transfer is linear. Only the owner
  can inflate it — a self-inflicted transfer DoS; a cap (e.g. 16) would cost ~20 B.
- **I-3** 4 fork tests skip without `BASE_RPC`; `moveLiquidity` and the fee events were never run on
  live v4.

## 8. Verified and found correct (for the record)

- `_hooksAllowed()` — a `pure` predicate, constant-folded; Stable/Volatile byte-for-byte the same size;
  no setter ([H-7]/[M-7] stay closed).
- task_044's claim "no re-entry through a hook": verified — `PoolManager.unlock` during the callback →
  `AlreadyUnlocked`; `unlockCallback` behind `NotPoolManager`; every value entry `nonReentrant`; `_mint`
  without `onERC721Received`. What remains is read-only reentrancy of view functions (UI-level).
- `byOwner` in the unlock payload is trusted correctly: the PoolManager calls back only `msg.sender`,
  with the same data.
- `_skimFees(key, salt, fees)` — event only, skim logic unchanged; the double call in recenter/reinvest is
  guarded by `(f0|f1) != 0`.
- `operatorList` splice / `_clearOperators` — consistent; same storage slot (`_operatorList` →
  `operatorList`), no upgrades.
- `MAX_POOLS = 32`: every loop is bounded by owner config; `initialize` ~4.8M gas; `_settleManaged`
  ≤ 64 currencies.
- `moveLiquidity`: registry consistent, including `add.salt == fromSalt` (full pull + new range; partial +
  `RangeMismatch`); a single `_settleManaged`; `ZeroLiquidity` on a zero pull.
- `LPManagerFactory` unchanged since v2.0.0; L-FAC-1 closed (`keccak(initData)` in the salt).
- `ChainlinkPriceOracle._read`/`_sequencerUp`: staleness, future `updatedAt`, `answer ≤ 0`, sequencer
  down/grace — correct, fail-closed for operators.
- Solidity 0.8.26 / cancun / PUSH0: target chains (Ethereum, Arbitrum, Base, Unichain) support it.

## 9. Next steps

1. Open `tasks/task_053` for H-1 (option A + a new `ChainlinkPriceOracle` with the spot branch + tests
   modelled on `VolatileLPManagerOperatorSwapGuard.t.sol`; this audit's PoC test must start **failing**
   with `OperatorSwapUnverified`).
2. M-1/L-3 — same oracle release (`Ownable2Step`, cap on `maxDeviationBps`, `minAnswer/maxAnswer`).
3. L-1/L-2 — next Volatile release (≈40 B total; ~150 B left after A).
4. L-4/I-1 — NatSpec fixes and a note for stablelp-ui / mcp-lp.
