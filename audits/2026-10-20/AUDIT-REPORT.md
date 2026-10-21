# Security Audit: release v2.2.0 before deploy (tasks 055–059)

**Date:** 2026-10-20
**Project:** `uniswap-smart-wallet` (Envelop V2 / unisafe LP managers)
**Revision:** `master` at `8ed3e29`; diff reviewed `9dd61b5..8ed3e29`
**Focus:** theft paths and math correctness in what v2.2.0 adds; integration breaks the deploy causes.
**Status as of 2026-10-21:** see the Status column in §3. v2.2.0 was deployed on 2026-10-21 with the
HIGH fixed.

---

## 1. Scope

| Task | What changed |
|---|---|
| 055 | `WalletPositionDescriptor` rewrite: USD from Uniswap pools (stable allowlist, reference pools, own-pool fallback), escaping, bounded `symbol()`/`decimals()` reads |
| 056 | EIP-170 headroom: `cbor_metadata = false`, shared `MetadataUpdate`, low-level `executeEncodedTxBatch`, `tokenURI` try/catch, pre-validation moved into `unlock` |
| 057 | `address oracle` in both `InitParams`, set at `initialize` |
| 058 | `moveLiquidity(fromSalt, liquidity, add, BridgeSwap)`: a pre-swap in any configured pool before the add (Volatile/Open) |
| 059 | Card shows Liquidity and Unclaimed Fees, no APR |

Also in scope: `script/chain_params.json`, `CreateManager.s.sol`, `DeployDescriptor.s.sol`, and the
stablelp-ui code that reads what changed (`initData`, the share card, position history).

**Threat model (unchanged from `2026-09-04`).** External callers cannot reach value functions. The
actors that matter: a compromised or malicious **operator**, token behaviour, accounting bugs, and
for the descriptor, someone who wants a manager NFT's card to lie to a buyer. The owner harming
itself is not a finding.

## 2. Methodology

One orchestrated run, 57 agents, 43 minutes.

1. Eight review dimensions in parallel: descriptor math, manager math, auth after the 056 refactor,
   theft through the 058 bridge, the 057 init oracle, descriptor security, config and scripts,
   integration with stablelp-ui.
2. Every candidate went to independent verifiers told to refute it, with the code at `8ed3e29` and,
   where possible, a Foundry PoC. A finding survives if verification could not refute it. Where a
   verifier agreed with the facts but disputed the severity, the table says so.
3. A completeness critic read the whole diff again for anything the dimensions missed. It found
   nothing new.
4. The HIGH was reproduced by two separate PoCs (§4, [`poc/`](poc)).

Not covered: tasks 060–064, which landed after this audit (060 is the fix for H-1). They were reviewed
as ordinary changes with their tests, not by a second audit run.

24 confirmed findings came out of the run; duplicates from different dimensions are merged below
into 17.

## 3. Result

| ID | Severity | Status | Title |
|---|---|---|---|
| **H-1** | **HIGH** | **FIXED** in v2.2.0 (task_060, `55a694a`); old impls revoked (task_062, `ce7c65b`). **Existing v2.1 managers cannot be fixed** | An operator round-trips a notional far above the manager's holdings inside one op; a JIT-LP operator takes ~2·fee·notional |
| M-1 | MEDIUM | FIXED (stablelp-ui task_181, `d43c362`, shipped with the deploy) | Manager creation in stablelp-ui breaks against v2.2: `initData` has no `oracle` field |
| L-1 | LOW | Open | The card values holdings at the creator's own-pool spot and prices them at reference prices; moving the own pool away always raises the figure, and the card still says "reference pools" |
| L-2 | LOW | Open | A truncated card (> 40 positions) drops the "own pool" warning |
| L-3 | LOW | Open | A third party can create a manager owned by the victim with a planted oracle that approves everything |
| L-4 | LOW | Open | The Unichain $1 allowlist includes yield-bearing sUSDC and sUSDS (~$1.11 each) |
| L-5 | LOW | Open, display only | Reference pools are read at spot (`slot0`); a thin reference pool moves every card's figure in one tx |
| L-6 | LOW | FIXED (stablelp-ui task_181) | The share card reads `Total Value (USD)`, which the v2.2 descriptor no longer emits |
| L-7 | LOW | FIXED (stablelp-ui task_181) | Position history drops the entry basket of a 4-argument `moveLiquidity` |
| I-1 | INFO | Open | The shared chain oracle is now the default guard of every new manager; its owner is a single EOA |
| I-2 | INFO | Open | The descriptor owner (same EOA) can show any value on every card on the chain; the v3 `slot0` read is not gas-bounded |
| I-3 | INFO | Accepted, documented | `tokenURI` still reverts when the descriptor returns data that does not decode as a string (including a code-less descriptor) |
| I-4 | INFO | Accepted, documented | `executeEncodedTxBatch` calldata to a code-less target now succeeds as a no-op |
| I-5 | INFO | Superseded by H-1's fix | The move bridge is a second oracle-gated swap per operator op |
| I-6 | INFO | Open | `DescriptorLib.clean` lets U+FFFE / U+FFFF through, which XML 1.0 forbids; the SVG breaks |
| I-7 | INFO | Open | The mainnet $1 allowlist includes sUSD, which has traded well below $1 |

## 4. H-1: operator round trip, notional not bounded by holdings

**Where:** `VolatileLPManager._handleMove` (bridge `_guardedSwap`, then the `add` pre-swap),
multi-leg `allocate` on all products; `ChainlinkPriceOracle._checkSwap`.

**Cause.** The oracle checks each swap on its own: `amountOut ≥ (1 − θ)·fair`, θ = 100 bps. A swap
that loses only the pool fee passes. `_settleManaged` settles the net delta once, at the end of
`unlock`, so inside one operation the manager's delta can go far negative and the swap notional is
not tied to what the manager holds. Two opposite swaps of notional A cost the manager about 2·fee·A
from its balance. That fee goes to the LPs in the current tick, which with JIT liquidity is almost
entirely the operator.

The `2026-09-04` accepted residual (θ − fee per op) silently assumed the volume is bounded by
holdings. Here the notional is ~50× holdings.

**What 058 added.** The bridge is a second swap in the same op, with any configured pool and any
`amountIn`. Nothing stops `bridge.poolId == add.poolId` in opposite directions. The root cause is
older: a two-leg operator `allocate` does the same, and that path is in production v2.1.0.

**PoCs** (real `ChainlinkPriceOracle(100, 50, 10)`, 0.3 % pool, operator set with `setOperator`):

| PoC | Path | Manager | Operator |
|---|---|---|---|
| [`poc/AuditBridgeRoundTrip.t.sol`](poc/AuditBridgeRoundTrip.t.sol) | move with bridge, A = 1000e18, JIT L = 1e24 | 19.99e18 → **14.01e18** (−30 %) | +5.99e18 |
| same file | two-leg `allocate`, A = 700e18 (v2.1.0 path) | 20.0e18 → 15.8e18 | +4.19e18 |
| [`poc/PoCRoundTripFeeDrain.t.sol`](poc/PoCRoundTripFeeDrain.t.sol) | move with bridge, V = 15,000e18, JIT L = 1e27 | 100/100 → 8.86 / 101.27 (≈ −45 %) | +91.1 c0, −1.28 c1 |

One operator call each, repeatable every transaction until the manager is empty. Both PoCs build on
`RedTeamBase` from [`../2026-09-04/fix-review/poc/RedTeamTask053.t.sol`](../2026-09-04/fix-review/poc/RedTeamTask053.t.sol):
copy both into `test/` at `8ed3e29` and run `forge test --match-path 'test/*RoundTrip*' -vvv`.

**Fix (task_060).** `BaseLPManager._boundOperatorSwap`, operator swaps only:

1. After the swap, `currencyDelta(in) + balanceOfSelf(in) ≥ 0`, else
   `OperatorSwapExceedsHoldings(Currency)`. Liquidity pulled in the same op counts as holdings.
2. A currency sold earlier in the op cannot be bought back, directly or around a cycle, else
   `OperatorSwapRoundTrip(Currency)`.

The PoCs are regression tests in `test/OperatorSwapBound.t.sol` and revert with
`OperatorSwapExceedsHoldings`.

**Residual risk.**

- Loss per op is now ≤ θ × holdings; in the PoC setup ≤ $0.20 instead of $6.
- Turnover across transactions is not closed: X→Y in one tx and Y→X in the next each still pay the
  pool fee to a JIT operator. A cooldown or a turnover limit is a separate decision.
- **v2.1 managers are non-upgradeable clones and keep the bug.** task_062 revoked the v2.0/v2.1
  impls on the factory at deploy (no new vulnerable clones). For existing managers the only
  mitigation is to give the operator role to trusted keys only.

## 5. Other findings

**M-1. `initData` without `oracle`.** v2.2 `InitParams` has a new field, so the `initialize` selector
changed; the old frontend encoding would hit a selector the impl does not have, and nobody could
create a manager. The verifier rated it a known deploy follow-up rather than a defect. Fixed by
stablelp-ui task_181 (`oracle` from the chain's deployment), deployed together with the contracts.

**L-1. Own-pool split.** `positionValue` splits liquidity at the manager's own pool `slot0` and prices
each leg at reference prices. With own price p′ and reference p, V(p′) = x(p′)·p + y(p′) and
dV/dp′ = x′(p′)·(p − p′): V is minimal at p′ = p, so any move of the own pool raises the card. A
full-range position with the own pool pushed 100× shows 5.05× its value (10×: 1.74×). Both legs are
referenced, so the card says "reference pools". One verifier refuted it as a vulnerability (display
only, nothing on-chain reads it); the rest kept LOW. Fix for the next descriptor: split at the
reference-derived price, or flag OWN_POOL when the two prices differ by more than 1–2 %.

**L-2. Truncation hides "own pool".** `_pricing` returns `truncated` before `own pool`, and the SVG note
prefers "first N of M". A manager with > 40 positions whose value comes from a thin own pool shows
"≥ $X" with no caveat. Fix: print both flags.

**L-3. Planted oracle.** `LPManagerFactory.createManager` is permissionless and takes any
`expectedOwner`; since 057 the creator also picks the oracle. A third party can create a manager
owned by the victim with an oracle that approves everything. It only matters if the victim funds it
and enables an operator that turns malicious. Fix (off-chain): flag managers whose `priceOracle()`
is not the chain's oracle from `deployments/<chain>.json`, in the UI, MCP and insight.

**L-4, I-7. Allowlist.** `chain_params.json` lists sUSDC and sUSDS (vault shares) on Unichain and sUSD on
mainnet as $1 stables. The deployed descriptors have them. Fix: `setStable(token, false)` on the
deployed descriptor and a reference entry if they need pricing.

**L-5. Spot references.** `_usd` reads `slot0` of v3 and v4 reference pools. Moving a thin reference
(ETHFI on Arbitrum, UNI on Unichain) moves every card that uses it, for the cost of a swap. No funds
are at risk; nothing on-chain or in MCP/insight reads descriptor prices. Accepted as display-only for
now; drop the thinnest references or read a TWAP if it matters.

**L-6. Share card.** `managerMeta.parseStats` required `Total Value (USD)`. Fixed in task_181: it reads
`Liquidity (USD)` / `Unclaimed Fees (USD)` with a fallback, and keeps the position count when the USD
attributes are absent.

**L-7. History.** `decodeAllocateLegs` knew only the 3-argument `moveLiquidity`. Fixed in task_181 with
the re-synced ABI; viem picks the overload by selector.

**I-1, I-2. Admin keys.** `CreateManager.s.sol` now wires the chain's `ChainlinkPriceOracle` into every
new manager by default. Its owner can register any aggregator (`setFeed`) and relax tolerances. The
owner cannot steal alone, but together with any operator it removes the guard. The descriptor's
owner (`setStable`, `setReference`) controls every card on the chain; `initialOwner` is zero in
`chain_params.json`, so it is the broadcaster. Checked on-chain 2026-10-21: both are the EOA
`0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D` on chains 1, 130, 8453 and 42161. Fix: move both to a
multisig and/or timelock (`Ownable2Step` is in place). Also route the v3 `slot0` read through
`_boundedCall`.

**I-3. `tokenURI`.** try/catch catches a reverting descriptor, but a successful call whose return
data does not decode as `string` (a code-less descriptor returns empty data) still reverts. The
NatSpec states it. Nothing on-chain reads `tokenURI`.

**I-4. `executeEncodedTxBatch`.** The 056 move to a raw `call` drops OZ's `AddressEmptyCode`. Owner-only;
the risk is a mistyped or wrong-chain rescue that "succeeds" doing nothing. Documented in the code;
clients should check the balance delta.

**I-5. Second swap per move.** True as stated, but the per-op bound it doubles was never a per-op
bound (see H-1). H-1's fix bounds total notional by holdings, which covers it.

**I-6. U+FFFE / U+FFFF.** `_seqLen` accepts `EF BF BE` / `EF BF BF`. A token symbol or manager name with
them breaks the SVG image (JSON is fine). Fix: replace them with `?` in the `!json` branch.

## 6. Open items

All open items are display, configuration or key management; none moves funds without the operator
or admin being malicious.

- Descriptor fixes (L-1, L-2, I-2 bounded read, I-6) need a new descriptor; existing managers pick it up
  with `setPositionDescriptor`.
- Allowlist cleanup (L-4, I-7) is a `setStable` call on the deployed descriptors.
- Admin keys to a multisig (I-1, I-2).
- Planted-oracle warning in UI/MCP/insight (L-3).
