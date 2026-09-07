# Fix review — an audit of the H-1 remediation

**Date:** 2026-09-06 (statuses updated 2026-09-07) · **Subject:** commits `d31fdb0`, `4e9e784`,
`8231fa5`, `a96ea5a` on branch `audit/2026-09-04` (`git diff master..HEAD -- src script`)
**What was fixed:** [H-1](../AUDIT-REPORT.en.md) (HIGH, PoC) — swapless operator ops deploy principal
at a skewed spot price; the PoC took −22.4 % of the portfolio via `moveLiquidity` and −44.5 % via
`recenter`.

## Verdict

**H-1 was reduced, not closed.** An instant theft became a fast bleed: 47 bps per operation instead of
44.5 %, but the bound applies **per operation**, not per transaction — 60 operations in a single
transaction take **24.84 %** of the portfolio. Separately, on `OpenVolatileLPManager` the original
attack reproduces **in full**: a hook moves the price after the oracle has vouched for it.

This did **not** block the `RUNBOOK-2026-09-05.md` run (it carries `openImpl: false`, and for the
hookless products the fix is a strict improvement; clones are not upgradeable, so delaying would mean
new managers carrying the full H-1). It did block three things: deploying `OpenVolatileLPManager`,
pointing the bot at `tickSpacing ≤ 10` pools without a rate control, and the `oracleMaxSpotDeviationBps`
value on chain 130.

**All of this is now remediated in task_054** — see the Status column below.

## Method

| Layer | Scale | What it found |
|---|---|---|
| Adversarial code review | 83 agents: 7 lenses × 3 refuters, a completeness critic, 4 targeted sweeps | 60 raw → 18 verified → 15 survived + 8 from the sweeps |
| Red team, executable PoCs | 23 tests against the **real** `ChainlinkPriceOracle` | 2 HIGH with working exploits |
| Differential fuzzing | 18 tests against an independent exact-rational model | 1 MEDIUM (latent), 2 LOW |

Every finding below was re-verified independently by the lead auditor; raw reports are in
[`raw/`](raw/), PoC sources in [`poc/`](poc/).

**A methodological note worth keeping.** 83 agents reading code concluded "the fix closes H-1 as
claimed". One agent that **wrote and ran tests** disproved that with two exploits. Code review does not
substitute for execution.

## Findings

| # | Severity | Finding | Blocked | Status |
|---|---|---|---|---|
| **R-1** | **HIGH** | A hook restores H-1 in full on `OpenVolatileLPManager`: the price moves between the guard and `modifyLiquidity` | the Open deploy | **CLOSED** — spend cap in `_checkOwed` (Open) |
| **R-2** | **HIGH** | The residual is bounded per operation, not in total: 60 ops in one transaction = −24.84 % | the bot on thin pools | **CLOSED** — midpoint gate (`checkOp`, θ) + 1 call/tx; the spacing rule was withdrawn after measurement |
| R-3 | MEDIUM | The gate's price resolution is coarser than its own tolerance; at extreme decimals it accepts up to 96.5 bps against a 50 bps setting | no (latent) | **CLOSED** — `MIN_PRICE_RESOLUTION` |
| R-4 | MEDIUM | `oracleMaxSpotDeviationBps: 50` sits below the basis this repo itself measured on Unichain (72 bps); the recalibration is absent from the runbook | the chain-130 parameter | **CLOSED** — per-chain values from a measured sample, 2026-09-07 |
| R-5 | MEDIUM | A new manager is born with `priceOracle == 0`, which now means its operator can do nothing; on Stable there is no UI to fix it | no | FRONTEND — `stablelp-ui` task_091 |
| R-6 | MEDIUM | Griefing DoS: a third party blocks an operator transaction for 0.063e18 | no | ACCEPTED — the owner bypasses the guard |
| R-7 | MEDIUM | An operator's own pre-swap reverts its own add at ~25–30 bps of pool depth | no | ACCEPTED — planner task |
| R-8 | MEDIUM | The guard's meaning changed but every documentation surface outside the diff still says "swap"; `IPriceOracle` does not document the sentinel | no | **CLOSED** — docs, natspec, `IPriceOracle.checkOp`, `UniLens` (2 fields) |
| R-9 | LOW | The Stable half of the fix is pinned by no test: two mutations that reopen H-1 leave all 293 tests green | no | **CLOSED** — the mutation now breaks tests |
| R-10 | LOW | The `MAX_TOKEN_DECIMALS` comment is wrong; at `td0−td1 ≥ 27` a bare revert instead of "no opinion" | no | **CLOSED** — `MAX_TOKEN_DECIMALS = 24` |
| R-11 | LOW | Two unguarded operations on line 292 give `Panic(0x11)`; `feedDecimals` unbounded | no | **CLOSED** — `MAX_FEED_DECIMALS` + `mulDiv` |
| R-12 | LOW | The sentinel-safety argument is false: `_handleReinvest` has no full-fill check | no | **CLOSED** — `SwapSlippage` in reinvest |
| R-13 | LOW | The documented remedy for a stale bounds cache is a no-op: `SetOracleFeeds` skips exactly the phase-change case | no | **CLOSED** — `refreshBounds` |
| R-14 | INFO | `setApprovalForAll` on the manager is a total bypass of the guard | no | FRONTEND — UI warning |
| R-15 | INFO | Tolerance asymmetry at the 1000 bps cap: 1.22× further down than up | no | **CLOSED** — natspec |

---

## R-1 — HIGH. A hook restores H-1 in full on `OpenVolatileLPManager`

**PoC:** `poc/RedTeamT2HookBypass.t.sol::test_T2_hookWarpsPriceAfterTheOracleVouched`

The guard sits at `src/VolatileLPManager.sol:288`, the add is priced at `:293`. In between, v4 invokes
`hook.beforeAddLiquidity` (`PoolManager.sol:156` runs the hook, `:159` runs `pool.modifyLiquidity`).
The lock is still open, so the hook re-enters `PoolManager.swap`, moves the price and settles its own
deltas. The oracle vouched for a price that no longer exists when v4 computes what the manager owes.

The hook needs **no** delta-returning permission — only `BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY`.

| | |
|---|---|
| oracle vouch before the call | `check(key,true,0,0) == true`, pool exactly on the reference |
| manager value before / after | 2 000e18 → 1 100.06e18 |
| **loss in one vouched-for call** | **899.94e18 = 44.997 % of the portfolio** |
| hook gain | 899.37e18 (99.94 % transfer) |
| control, same call, hook idle | −1 wei |

The skew is **unbounded** — `maxSpotDeviationBps` never sees it. Collateral: `test_T2_ownedExceedsDesired`
breaks the `_addLiquidityAt` docstring invariant ("owed ≤ the desired amounts by construction") — a leg
with `amount1Desired == 0` made the manager spend 999.95e18 of currency1.

**Why this is not merely "a malicious hook is the owner's problem".** The header of
`src/OpenVolatileLPManager.sol:26-50` enumerated accepted residuals 1–3 and then asserted: *"What is NOT
on that list, despite hooks now running inside our `unlock`: re-entrancy."* That is wrong for the add
path. It also called the oracle guard "inherited unchanged", implying it works. `CLAUDE.md` repeated it.

**The hookless products are immune by construction** (`test_T2_hooklessProductHasNoSuchWindow`):
`_hooksAllowed() == false` ⇒ `key.hooks == address(0)` ⇒ nothing to warp from.

**Remediation (task_054).** Re-reading `slot0` after the add does **not** work — the hook restores the
price inside `afterAddLiquidity`, so the second check sees a clean pool while the manager is still down
45 %. The damage is in the pricing of the add itself, and after the price is restored the only surviving
evidence is the bill. `_addLiquidityAt` now passes the caller delta, net of realized fees, to a
`_checkOwed` hook — empty in the base products, where the invariant holds by construction — which
`OpenVolatileLPManager` overrides with the spend cap (`OwedExceedsDesired`). The PoC now reverts.

## R-2 — HIGH. The residual is bounded per operation and unbounded in total

**PoC:** `poc/RedTeamT1Residual.t.sol::test_T1a`, `test_T1c`, `test_T1d`

Staying **inside** the tolerance: skew to tick +49 (+49.12 bps against a 50 bps cap), swapless
`recenter` into the narrowest legal range at that price, return the price to the **opposite** edge of
the band. The return leg lands at −49 bps — which is the setup for the next operation: the skew is paid
for once and harvested indefinitely.

| measurement | value |
|---|---|
| loss per operation (fee 100, spacing 1) | **47.38 bps** of the portfolio; attacker gains 47.12 bps |
| control: same price path, no operator op | manager **+2 bps** (it earns fees) |
| 40 operations, 40 transactions | 17.33 % |
| **60 operations in ONE transaction** (contract operator) | **24.84 %**, 29.5 M gas |

`nonReentrant` does not bite — the calls are sequential, not nested. No cooldown, no per-epoch cap, no
value floor. At ~490 k gas per operation that is ~60 per Ethereum block and far more on Unichain or
Arbitrum: no off-chain monitor can interpose inside a transaction.

**The residual formula, corrected:** not `d − fee` but `d − tickSpacing/2 − fee`. By fee tier (narrowest
legal range each): 0.01 % → 47 bps, 0.05 % → 29, **0.30 % → 0, 1 % → 0**. The attack lives only at
`tickSpacing ≲ 10`.

**Pool depth bounds the thief, not the vandal.** The manager's loss is **depth-independent** — 47 bps
every time. Only the attacker's profit depends on depth: +4.73e18 at 2 000e18 of pool liquidity, and a
**loss of 8.74e18** at 2 000 000e18. Break-even is around 500–700× the manager's principal. On deep
pools the attack is unprofitable but still fully destructive.

**Remediation (task_054), in two steps — the first of which was withdrawn.**

The first attempt refused any pool whose `tickSpacing` was finer than `maxSpotDeviationBps`. Live
measurement killed it: at the shipped `d = 50` that denied operators most pools on every chain and
**all three on Unichain**, and six pools had `basis ≥ spacing`, which no tolerance can admit. It was a
*width* rule in disguise — taking pools away in order to forbid a narrow position indirectly.

The quantity the attack actually turns on is the **distance from the parked range's midpoint to the
reference**: sweeping the price through a range converts the principal at the range's average price,
which is its midpoint. So the oracle now bounds that distance directly — `maxMidOffsetBps` (θ) — and
the residual becomes linear and independent of tick spacing and width:

```
take ≈ θ − poolFee
```

Measured on the drain's own pool (`fee 100`, `spacing 1`, `test_R2_takeIsThetaMinusFee`): θ = 5 → 3 bps,
θ = 10 → 8, θ = 20 → 18 — each exactly `θ − fee − ½ tick` of lattice rounding. A wide range centred at θ
takes ≤ 2 bps. **No pool is taken away**: a razor placed *at* the fair price is legal on a spacing-1
pool. The rule tells honest from skewed by the one thing that differs — the reference follows the
market, the pool follows its last swap.

`IPriceOracle` gained `checkOp`, one method carrying both the swap and the add arguments; two methods
cost two `PoolKey` encoders and put Volatile 47 B and Open 109 B over EIP-170. `check` remains for
already-deployed managers and for `StableLPManager`, whose ranges are fixed at `initialize`.

**Rate limit.** Independently, an operator now gets **one authorized call per transaction**, enforced by
a transient flag (EIP-1153) on `onlyAuthorized`. That drops the atomic drain from 24.84 % to one
operation. The multi-transaction variant survives (17.33 % over 40 transactions), but blocks now
separate the operations, so a watcher can see the pattern and the owner can revoke the operator.

**What operators give up, stated plainly:** a position must be centred on the reference within θ, so
deliberate asymmetry is bounded; and after a real market move the freed capital is one-sided, so the
honest flow is the (oracle-gated) pre-swap plus a centred re-add. A swapless one-sided re-add wider than
2θ is, by geometry, the parked range the rule exists to refuse.

## R-3 — MEDIUM (latent). The gate's resolution is coarser than its own tolerance

**PoC:** `poc/ChainlinkPriceOracleSpotFuzz.t.sol`

`src/oracle/ChainlinkPriceOracle.sol:289-296` — three integer truncations stack. `priceX96` is an
integer, so the comparison's grid is `1e4/priceX96` bps; `poolPrice`/`refPrice` are `humanPrice · 1e18`
as integers, a second floor of `1e4/refPrice`. Neither is checked against `maxSpotDeviationBps`.
Truncation is one-directional, so the accepted corridor does not merely widen — it **shifts** off the
reference, and in the dangerous direction: the pool price is understated, dragging an over-priced pool
inside.

At a 50 bps tolerance: **96.5 bps accepted** (td0=27, td1=0) and **1358.7 bps** (td0=18, td1=6 with
currency0 at ~$1e-16); in the other direction a legitimate 0.648 bps was rejected — a total DoS.

**Reachability** (re-derived independently): all four `script/oracle_tokens/*.json` configure only 6/8/18
decimals, and for the worst realistic pair (18 vs 6) the trigger needs currency0 below **$2.5e-15**. A
latent configuration hole, not a live exploit — but `setFeed` accepts `tokenDecimals` up to 36 and any
positive answer with no sanity check.

**Remediation:** `MIN_PRICE_RESOLUTION` — a price under the floor declines rather than comparing on a
grid coarser than the tolerance applied to it.

## R-4 — MEDIUM. The tolerance sat below the basis this repo measured

`_checkSpot` computes exactly the quantity `script/PriceDeviation.s.sol` prints as "basis".
`tasks/oracle_maxdeviation_analysis.md` (snapshot 2026-07-21) records **Unichain ETH/UNI at 72 bps** —
above the shipped tolerance on a calm day. The cause is in the same document: 18-decimal SVR proxies on
a 24 h heartbeat (`script/oracle_feeds.json`, chain 130, `heartbeat: 87300`), so a day-old answer passes
the freshness test and reaches the deviation comparison.

Two process defects sat on top of the number. `tasks/task_053_operator_add_spot_guard.md:80-81` made
re-running `PriceDeviation.s.sol` and taking a **high percentile** an explicit precondition; the runbook
that actually gets executed contained no mention of it. And the comment justifying the constant
(`script/DeployStableLP.s.sol:57-59`) cited snapshot 1 as "the last run" when snapshot 2 is the last run
on record and holds the readings that break the choice.

**Remediation (task_054).** The second iteration decoupled the two roles, which is what made this
closable: `maxSpotDeviationBps` now only has to cover the basis (a **one-sided** condition,
`basis_p99 < d`), because the attack residual is bounded by θ instead. A generous `d` no longer buys the
attacker anything. Values were set per chain from a measured sample — see
`tasks/oracle_maxdeviation_analysis.md`, section "2026-09-07".

## R-5 — MEDIUM. A new manager is born oracle-less, which now paralyses its operator

`priceOracle` is in neither product's `InitParams` (`StableLPManager.sol:50-55`,
`VolatileLPManager.sol:39-44`), is written only by the `onlyOwnerNFT` setter (`BaseLPManager.sol:332`),
and `script/CreateManager.s.sol` never calls it. Every clone from the new implementations therefore
starts with `priceOracle == address(0)`.

Before task_053 that meant "operators cannot swap". After it, the operator **cannot do anything**:
`allocate`, `allocateFrom`, `reinvest`, `recenter`, `moveLiquidity` all revert
`OperatorSwapGuardRequired`. The product's headline feature is dead on every new manager until the owner
sends a transaction nothing prompts them to send.

On Stable there is no in-app remedy at all: `OracleSection` is the only UI that calls `setPriceOracle`
and it is rendered under `{isVol && ...}`
(`../stablelp-ui/src/app/manager/[chainId]/[address]/operators/page.tsx:155`), even though the hook
behind it already writes with `StableLPManagerAbi`. Worse,
`../stablelp-ui/src/lib/errors.ts:9` renders `OperatorSwapGuardRequired` as "The owner can set one under
Oracle" — pointing a Stable owner at a card their product never renders.

**Status:** frontend task `stablelp-ui` task_091, item 1. It depends on nothing and can ship first.

## R-6 — MEDIUM. A cheap operator-DoS lever that did not exist before

**PoC:** `poc/RedTeamT3T4Denial.t.sol::test_T3a`–`test_T3c`

The gate is fail-closed and reads live `slot0`. Anyone who moves the pool 51 bps switches off every
operator liquidity operation in it. Cost of blocking **one** operator transaction: pool 4 000e18
(0.01 %) — **0.063e18**; 400 000e18 — 0.30e18; 40 000 000e18 — 24.06e18. Roughly
`2 × fee × depth × 60 bps`.

**Mitigating:** the owner bypasses the guard and can still recenter. The DoS hits automation, not
custody — hence MEDIUM, and hence accepted.

## R-7 — MEDIUM. An operator's own pre-swap reverts its own add

**PoC:** `poc/RedTeamT3T4Denial.t.sol::test_T4a`–`test_T4d`

The guard reads `slot0` **after** the operation's own pre-swap has moved it, and the spot tolerance is
tighter than the swap one. Threshold: about **25–30 bps of the pool's virtual liquidity** on the swap
input. The same 3 000e18 trade standalone realizes a 28 bps shortfall against the reference — the swap
branch returns `true` at a 100 bps tolerance with 3.5× of margin — while the spot branch refuses the
price that same trade produced. Multi-leg allocate accumulates drift and fails on the third leg.

**Status:** accepted; the remedy is in the planner (`stablelp-ui` task_091, item 4) — cap the pre-swap
well under 25 bps of pool depth and split multi-leg allocates in the same pool. Confirmed again during
task_054: the honest-recenter regression tripped this on its first attempt.

## R-8 — MEDIUM. Documentation outside the diff still described a swap guard

`src/interfaces/IPriceOracle.sol` did not document the `amountIn == 0` sentinel — the interface is
published, and a second implementation written in good faith would not guess it. `BaseLPManager` said
"operator **swaps**" in five places, including advice that could immobilise an owner's manager. `UniLens`,
redeployed in the same run, did not expose `maxSpotDeviationBps`.

**Remediation:** the sentinel is documented, `checkOp` is a first-class interface method with its own
natspec, `BaseLPManager` wording is corrected, and `UniLens.OracleStatus` now carries both
`maxSpotDeviationBps` and `maxMidOffsetBps`.

## R-9 — LOW. The Stable half of the fix was pinned by no test

Verified by mutation: replacing `_guardSwap(byOwner, key, true, 0, 0)` with `... true, 1, 0)` at
`src/StableLPManager.sol:215` left **all 293 tests green**. The mutation moves the call into the swap
branch, where for an equal-decimal pair `expectedOut` and `minOut` both round to 0 and `0 < 0` is false —
the plumbing stays intact while the price comparison becomes unconditionally satisfied.

Cause: `MockPriceOracle.RejectSpot`, added precisely to catch such mutations, was used only in two
Volatile tests; no Stable test drove a real `ChainlinkPriceOracle` through an add path.

**Remediation:** `..._consultsTheOracleOnSpot` for both allocate and reinvest, plus the missing
`..._notEnforcedOracle_reverts`. The mutation now fails two tests.

## R-10 — LOW. The `MAX_TOKEN_DECIMALS` comment named the wrong constraint

The comment reasoned about the **denominator** `Q96 * 10 ** tokenDecimals` ("room up to 48"). The binding
constraint is the **result** of line 290: `poolPrice == humanPrice · 1e18` overflows once the price
passes ~1.16e59. Measured: at `td0=36, td1=0` the first failure is at **tick 531 088**, inside
`MAX_TICK = 887 272`, and it is a **bare revert with empty returndata** — neither the custom error nor
the documented "no opinion". Independently re-derived: 531 087 for (36,0), 738 330 for (27,0),
1 083 735 for (18,6) — the last beyond `MAX_TICK`, hence unreachable at realistic decimals.

**Remediation:** `MAX_TOKEN_DECIMALS` lowered to 24, where the limit sits past `MAX_TICK`.

## R-11 — LOW. `Panic(0x11)` instead of "no opinion" on line 292

`refPrice = FullMath.mulDiv(a0, (10 ** fd1) * WAD, a1 * (10 ** fd0))` was the only price expression not
wholly inside `mulDiv`. `a1 * (10 ** fd0)` is a plain checked multiply (fd0=18 with
`a1 = type(uint256).max / 1e17` panics); `(10 ** fd1) * WAD` overflows at `fd1 ≥ 60`, and `feedDecimals`
came straight off the aggregator with no bound. The same shape pre-exists in the swap branch.

**Remediation:** `MAX_FEED_DECIMALS` bounds the aggregator at registration, and the live answer stays
inside `mulDiv`'s 512-bit intermediate.

## R-12 — LOW. The sentinel-safety argument failed on one path

The comment in `check` argued the sentinel is unreachable from a real swap because every swap path had
already required the realized input to be no smaller than the requested one. That full-fill check exists
in `VolatileLPManager._guardedSwap:225` and `StableLPManager._allocateLeg:189` but **not** in
`StableLPManager._handleReinvest`. The red team separately showed (`test_T5d`) that a v4 exact-in swap
can realize **zero** input and zero output while still moving the price, because `Pool.swap`'s loop has
no zero-liquidity guard.

No loss was constructed — a zero-fill swap moves no value and the subsequent add is still gated — but
defence in depth was broken. **Remediation:** the `SwapSlippage` check copied into the reinvest path.

## R-13 — LOW. The documented remedy for a stale bounds cache was a no-op

`setFeed`'s natspec advised re-running `SetOracleFeeds` after a Chainlink phase change. But `applyFeeds`
skips a currency whose `(aggregator, heartbeat, tokenDecimals)` already match — and a phase change swaps
the aggregator **behind** the registered proxy, leaving all three identical. The prescribed refresh
printed "skip (current)" and wrote nothing; a test pinned the skip as correct behaviour.

**Remediation:** an owner-only `refreshBounds(Currency[])` on the oracle, and the natspec now points at
it.

## R-14 — INFO. `setApprovalForAll` is a total bypass

`byOwner` comes from a strict `ownerOf(TOKEN_ID) == msg.sender` (`BaseLPManager.sol:339`), and
`setOperator` can never produce it. But the manager **is** the ERC-721: `setApprovalForAll(bot, true)`
lets the bot transfer the token to itself and become the owner — the guard is gone and `withdrawTo` is
open. The operator address is a hot key, so this warrants a UI warning (`stablelp-ui` task_091).

## R-15 — INFO. Tolerance asymmetry at the cap

The deviation is normalized by the reference, so the two directions are not equal widths measured
against the pool's own price: 1.03× at 50 bps (immaterial), **1.22× at the 1000 bps cap** (9.10 % vs
11.12 %). The natspec now says so.

---

## Checked and found correct

- **Add-path coverage is complete.** Every `modifyLiquidity` with a positive delta passes the guard
  (`StableLPManager.sol:221`, `VolatileLPManager.sol:293`); the remaining call sites
  (`VolatileLPManager.sol:159`, `StableLPManager.sol:258`, `:286`, `BaseLPManager.sol:490`) all pass
  `liquidityDelta ≤ 0`. `byOwner` is threaded correctly on all five reaching paths.
- **An operator cannot become the owner** through `setOperator` (see R-14 for the adjacent footgun).
- **The oracle is bound to its own `PoolManager`**: one built against a different one reads the pool as
  uninitialized and returns `false`. There is no configuration in which a skewed pool reads as vouched.
- **H-1 cannot be restored on the hookless products** — nothing can execute between the guard and
  `pool.modifyLiquidity` when `key.hooks == address(0)`.
- **The arithmetic is correct across the whole realistic domain**: decimal pairs (18,18), (18,6),
  (6,18), (8,18), (18,8), (6,6), prices $0.01–$60 000, ±60 ticks around the boundary — worst
  disagreement with the exact model **0.894 bps**, entirely explained by the final floor.
- **ABI compatibility preserved**: `maxDeviationBps()`, `sequencerUptimeFeed()`,
  `sequencerGracePeriod()`, `feeds()` as a 4-tuple — `UniLens.oracleStatus` and `SetOracleFeeds` work.

## Open questions

1. **Whether Stable needs the gate at all.** Its ranges are fixed at `initialize` with no setter, and
   its operator surface has no principal-removal path, so H-1's demonstrated mechanism does not reach
   it. Stable's exposure is idle balance plus realized fees deployed at a bad price into a fixed range;
   nobody has quantified that. A Stable arm of the PoC would settle it.
2. **The basis distribution.** Now sampled rather than snapshotted (2026-09-07), but the sample is
   intra-day. A longer series, ideally through a volatile window, would tighten the per-chain values.
3. **How often the fail-closed window actually bites.** The duty cycle of a >50 bps basis on Unichain
   volatile pairs is unmeasured.
4. **Whether a second `IPriceOracle` implementation is contemplated.** With `checkOp` now a documented
   interface method the risk is smaller than it was, but a second implementation still has to honour
   both bounds.
