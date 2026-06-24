# MetaStable — spike: a meta-stablecoin backed by productive stable LP

> **Status:** Design spike, **spec-only**. No code. Implementation may live in a **separate layer/repo**
> entirely; the only on-chain hook into this codebase is a small encumbrance mark in `StableLPManager`
> (see §3). This reframes the earlier "tokenize StableLPManager" idea: the ERC-20 is not a receipt — it
> is a **meta-stablecoin** minted against productive stable-LP collateral. Related:
> `spec_StableLPManager.md`, `StableLPManager_flows_ru.md`.

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

## 3. On-chain hook in `StableLPManager` (minimal, the only required change here)
The manager stays **NFT-owned by the minter**; tokenizing only adds an encumbrance the manager enforces:
- **State:** `mapping(bytes32 salt => uint128) encumbered` — collateralized (locked) liquidity per position.
- **Mint / lock (`tokenize(salt, L)`, owner-only):** raise `encumbered[salt] += L`, then mint noUSD via
  the external token contract.
- **Burn folded into `withdrawTo` (no separate redeem):** the liquidity-reducing path used by `withdrawTo`
  — `_pullLiquidity` (`src/StableLPManager.sol`), built on `_withdrawLiquidity`
  (`src/abstract/V4PositionManager.sol`) — gains a guard:

  > a pull may not drop a position's liquidity below `encumbered[salt]` **unless** the same call burns the
  > matching noUSD, lowering `encumbered[salt]` accordingly.

  So the only way to free locked collateral is to **retire (burn) noUSD**. `withdrawTo` stays
  `onlyOwnerNFT`.
- **EIP-170:** the manager has ~604 B of headroom. Keep its additions minimal (one mapping + the guard +
  `tokenize`); the **noUSD ERC-20 is an external contract** the manager mints/burns through. Even so the
  guard + `tokenize` may need a lever (lower `optimizer_runs`, a satellite accounting contract) — measure
  before committing.

## 4. Token denomination
One fungible noUSD over multiple heterogeneous positions needs **uniform backing per token**, else
burning tokens meant for position A could free position B and dilute A's backing. Options:
- **Pro-rata basket (recommended):** noUSD supply maps to the *whole* encumbered basket; freeing
  collateral via `withdrawTo` reduces **every** encumbered position ∝ the burned fraction. Keeps backing
  uniform and the token fungible.
- **Per-position token:** simplest backing, poor UX (a token per salt).
- **Shared protocol-level noUSD** across many minters/managers (a real stablecoin) vs a **per-manager**
  token — the protocol vision wants one shared noUSD backed by the aggregate of all minters' collateral.

## 5. Peg & redemption — the central open problem
What holds noUSD at $1?
- **Backing:** ~par stable collateral ⇒ intrinsic value ≈ $1, and a minter is economically forced to buy
  noUSD back (at ≤ backing) to unlock their collateral → a natural price floor + arbitrage.
- **v1 gap:** with owner-only `withdrawTo` there is **no holder-side force-redeem** — a holder trusts the
  market + minter buyback, not the code, for getting value out. A real stablecoin likely needs a
  **holder redemption path** (burn noUSD → pull collateral pro-rata, in-kind, autonomous) and/or
  **over-collateralization** + a stability module. This is the headline unsolved design question.
- **Inherited risks:** depeg of an underlying stable; the manager's existing assumptions carry over
  (no TWAP on sizing/swaps, standard-ERC-20 only — no FoT/rebasing); governance of *which* collateral
  (managers/pools) backs the shared noUSD.

## 6. Open questions (resolve before any implementation)
- Peg/redemption mechanism: holder force-redeem (in-kind) vs minter-buyback-only; over-collateralization;
  a stability module / PSM?
- Shared protocol-level noUSD vs per-manager token; who governs accepted collateral.
- Fee-accounting precision: noUSD backing must not double-count the **already-skimmed 10% protocol fee**
  (taken as ERC-6909 to the treasury via `FeeRedeemer`, not part of the minter's collateral).
- Liquidation: needed at all under ~par collateral? Trigger only on depeg of an underlying stable.
- Bytecode budget: does the manager hook fit EIP-170, or does it become a v2 manager / satellite?

## 7. Alternative (footnote, later)
A trustless multi-depositor version is the **ERC-7575 wrapper vault** (a vault holding the manager's NFT,
issuing shares, with par-NAV via `PositionState` and a holder-forced, possibly async, redemption). Heavier
(NAV, inflation-attack mitigation, redemption mechanics); revisit if/when holder-side trustless redemption
is required.

## Recommendation
Treat noUSD as a **separate protocol layer** built on top of `StableLPManager`, with only the small
`encumbered` hook landing in the manager. Keep prototyping deferred until the peg/redemption model (§5) is
chosen; prototype + audit the stablecoin layer independently of the core manager.
