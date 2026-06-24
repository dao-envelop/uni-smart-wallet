# MetaStable — spike: a meta-stablecoin backed by productive stable LP

> **Status:** Design spike, **spec-only**. No code. Implementation may live in a **separate layer/repo**
> entirely; the only on-chain hook into this codebase is a small encumbrance mark in `StableLPManager`
> (see §3). This reframes the earlier "tokenize StableLPManager" idea: the ERC-20 is not a receipt — it
> is a **meta-stablecoin** minted against productive stable-LP collateral. Related:
> `spec_StableLPManager.md`, `StableLPManager_flows_ru.md`.

## 0. Decision summary (v1)
Locked in discussion:
- **Model A — soft-peg, collateral-backed receipt.** Owner/minter-only `withdrawTo`, **no holder
  force-redeem**; peg is economic (minter buyback + mint pressure), not code-enforced. Hard peg (Model B
  / PSM) deferred.
- **Shared protocol-level noUSD** — one token over the aggregate of many minters' collateral, gated by a
  **governance registry of approved collateral managers**.
- **Minter keeps the LP fees** on locked collateral (the mint incentive).
- **Mint is 1:1 at par** — noUSD minted = par value of the locked collateral (each stable = $1), full
  collateralization, **no haircut / no LTV discount**. The oracle is used only for the depeg breaker
  (eligibility), not to discount the mint amount.
- **Depeg posture = lightweight** — oracle circuit-breaker + per-stable debt ceilings + an insurance
  buffer from the 10% fee + a governance whitelist (with a delist/wind-down path); **no liquidation**
  (owner-only preserved). A severe depeg is accepted tail risk; noUSD is soft-pegged, not hard-pegged.
- Still open (parameters): oracle source + deviation threshold, per-stable debt ceilings, buffer
  share/size, whitelist criteria, manager-hook bytecode budget.

## 1. Frame
A meta-stablecoin (call it **noUSD**) **collateralized by stable LP positions** held in
`StableLPManager`(s). Two properties make this attractive:
- **Tight peg by construction** — the collateral is stable-pair LP (~par), so the backing is itself
  ≈ $1-denominated; no volatile-asset liquidation cliffs.
- **Productive collateral** — the locked LP keeps earning V4 swap fees while it backs noUSD. The same
  capital does two jobs: backs a usable stablecoin *and* yields.

This is the capital-efficiency pitch: lock your stable LP, mint a liquid stablecoin to deploy elsewhere,
and keep the trading-fee yield on the collateral.

## 2. Roles
- **Minter** — a stable-LP **position holder** (a `StableLPManager` owner). A distinct protocol role:
  locks LP as collateral and mints noUSD against it. **The minter keeps the LP fees on the locked
  collateral — that yield is the explicit incentive to mint.** (This resolves the earlier open question
  about fees: fees go to the **minter**, by design. `claimFees`/`reinvest` on encumbered positions stay
  allowed — they are a feature, not griefing, because the minter *is* the collateral owner.)
- **Holder / user** — anyone using the circulating noUSD. In v1 has no on-chain redemption right
  (see §5); exits via the market.

## 3. Architecture — a three-component protocol layer
A *shared* noUSD over many minters needs a protocol layer; only the third component lands in this repo.
1. **`noUSD` ERC-20** — the shared stablecoin; `mint`/`burn` gated to the Controller (2).
2. **Controller / collateral registry** — the protocol layer: **approves** collateral managers
   (governance), enforces a **global LTV**, and routes `mint` (on lock) / `burn` (on unlock). Approval
   criteria: hookless stable pools only (already enforced by the manager), pool depth, which stables
   count as $1. This is where the trust/governance sits.
3. **Per-manager encumbrance hook** (the only change in this repo). The manager stays **NFT-owned by the
   minter**; tokenizing adds an encumbrance it enforces:
   - **State:** `mapping(bytes32 salt => uint128) encumbered` — locked liquidity per position.
   - **Lock (`tokenize(salt, L)`, owner-only):** raise `encumbered[salt] += L` and call the Controller to
     mint noUSD (Controller checks approval + LTV).
   - **Burn folded into `withdrawTo` (no separate redeem):** the liquidity-reducing path
     `_pullLiquidity` (`src/StableLPManager.sol`, built on `_withdrawLiquidity` in
     `src/abstract/V4PositionManager.sol`) gains a guard — a pull may not drop a position's liquidity
     below `encumbered[salt]` **unless** the same call burns the matching noUSD (via the Controller),
     lowering `encumbered[salt]`. `withdrawTo` stays `onlyOwnerNFT`.
   - **EIP-170:** ~604 B headroom. Keep the manager addition minimal (the mapping + the guard +
     `tokenize`); the noUSD token and Controller are external. Even so it may need a lever
     (`optimizer_runs`, a satellite) — measure before committing.

## 4. Mint valuation & token denomination
A shared, fungible noUSD with **uniform backing** requires valuing collateral at mint and reducing it
uniformly at burn:
- **Mint is 1:1 at par.** noUSD minted = the par value of the locked collateral — the position principal
  (`src/lib/PositionState.sol`) with each managed stable counted as $1. Full collateralization, no
  haircut and no LTV discount. The oracle is used only to gate eligibility (the depeg breaker, §5a — a
  stable that is off-peg can't be minted against), not to size the mint. Valuing at par rather than the
  pool's internal price avoids pool-price manipulation at mint.
- **Uniform un-encumber:** freeing collateral burns noUSD ∝ the value released, so backing-per-token
  stays uniform across all minters (locked collateral can never leave without a matching burn).

## 5. Peg & redemption — decided: v1 = Model A (soft-peg receipt)
**Decision:** v1 noUSD is a **soft-peg, collateral-backed receipt** — owner/minter-only `withdrawTo`,
**no holder force-redeem**. A code-enforced hard peg (Model B / PSM) is a later upgrade.

- **Backing is structurally present.** Locked collateral cannot leave the manager without burning the
  matching noUSD, so the outstanding supply is always backed by the encumbered ~par LP. But holders
  **cannot redeem on-chain** — they realize value via the secondary market.
- **Soft-peg mechanism (economic, not code-guaranteed):** *floor* — a rational minter buys noUSD back
  (at ≤ backing) because burning it is the only way to unlock their collateral; with a shared token the
  cheapest-to-unlock minter arbs. *Ceiling* — noUSD above backing makes minting profitable, so minters
  mint more and supply rises. Both pressures are economic, so the peg **can drift under stress with no
  on-chain backstop** — the accepted v1 tradeoff. This is a step toward a hard-pegged stablecoin, not the
  final form.
- **Inherited risks:** depeg of an underlying stable; the manager's existing assumptions carry over
  (no TWAP on sizing/swaps, standard-ERC-20 only — no FoT/rebasing); governance of *which* collateral
  (managers/pools) backs the token.

### Future (hard peg) — Model B
Add a holder-callable **in-kind redemption** (burn noUSD → pull collateral pro-rata, autonomous) and/or a
**PSM + over-collateralization** to turn the soft floor into a code-enforced one. Deferred.

## 5a. Depeg of a collateral stable (v1 — lightweight handling)

**Failure mode.** If a collateral stable (say DAI) drops to $0.80, arbitrage swaps the cheap token into
the minter's pool and takes the good one out; on a narrow range the position exits the range and becomes
~100% the bad token. The collateral, counted at par, is now worth less than the noUSD minted against it.
Because noUSD is shared and there is no liquidation (Model A), the cheapest-to-unlock (good-collateral)
minters buy discounted noUSD and pull their good collateral first, leaving noUSD backed by the broken
asset — an adverse-selection run. This is the main systemic risk of the design.

**Lightweight mitigations (chosen):**
- **Oracle per stable** — used for the breaker and for mint valuation (§4).
- **Circuit-breaker** — deviation beyond a threshold pauses new mints against any collateral that holds
  that stable.
- **Per-stable debt ceiling** — no single stable backs more than Y% of supply. Caps the blast radius.
  (Mint is 1:1 at par, so there is no per-unit haircut buffer — the buffer is the only cushion.)
- **Insurance buffer** funded by the existing 10% protocol fee (routed via `FeeRedeemer`/treasury) —
  absorbs bad debt up to its size, so small depegs keep the peg.
- **Governance whitelist** — only vetted stables are accepted as collateral.

**Whitelist resolution scenario.** The whitelist is the governance lever that turns a run into an
orderly wind-down:
1. Oracle flags the depeg; governance **delists** the stable. New mints against any collateral holding
   it stop, and its value in the backing/LTV accounting is **marked down to the oracle price** (so the
   protocol stops pretending it is $1).
2. Affected minters get a **cure window**: rebalance the position out of the bad token (swap it for a
   still-whitelisted stable via the manager's allocate/withdraw, while it retains value) and/or burn
   noUSD to lower their encumbrance back to a healthy ratio. Acting early salvages the most.
3. After the window, any shortfall is covered by the **insurance buffer**; residual beyond the buffer is
   written down / socialized to noUSD holders.
4. If the stable re-pegs, governance can **re-list** it.

**Residual risk (accepted).** These limit and slow the damage but do not eliminate a run on a *severe*
depeg: loss beyond buffer + haircut is socialized, and the breaker cannot unwind already-minted noUSD, so
noUSD soft-depegs until the bad collateral is cured or written off. No liquidation backstop, by design —
this is the explicit tail risk of a soft-pegged v1.

## 6. Open questions (remaining parameters — peg model & token structure already decided in §0)
- **Mint ratio:** decided — **1:1 at par**, full collateralization (no haircut / LTV). Consequence: the
  only cushion against a depeg is the insurance buffer (§5a), not over-collateralization.
- **Governance:** the body that approves collateral managers (admin/multisig/DAO) and the criteria
  (depth, accepted stables, per-manager mint caps).
- **Valuation precision:** par-valuation must not double-count the already-skimmed 10% protocol fee
  (taken as ERC-6909 to the treasury via `FeeRedeemer`, not part of the minter's collateral).
- **Depeg parameters (§5a):** oracle source + deviation threshold; per-stable debt ceiling; buffer's
  share of the 10% fee + its target size; cure-window length.
- **Liquidation:** out of scope for v1 (decided) — lightweight posture instead (§5a).
- **Bytecode budget:** does the manager hook fit EIP-170, or does it become a v2 manager / satellite?

## 7. Alternative (footnote, later)
A trustless multi-depositor version is the **ERC-7575 wrapper vault** (a vault holding the manager's NFT,
issuing shares, with par-NAV via `PositionState` and a holder-forced, possibly async, redemption). Heavier
(NAV, inflation-attack mitigation, redemption mechanics); revisit if/when holder-side trustless redemption
is required.

## Recommendation
Treat noUSD as a **separate protocol layer** built on top of `StableLPManager`, with only the small
`encumbered` hook landing in the manager. Keep prototyping deferred until the peg/redemption model (§5) is
chosen; prototype + audit the stablecoin layer independently of the core manager.
