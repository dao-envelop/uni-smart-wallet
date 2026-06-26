# StableLPVault — tokenization spike (design only, NO code)

> **Status:** Design spike. Captures the shape and the hard problems of *optionally* tokenizing a
> `StableLPManager` into fungible shares, so a decision can be made before any prototype. Nothing here
> is implemented. Related: `spec_StableLPManager.md`, `StableLPManager_flows_ru.md`, `FeeRedeemer.sol`.

## Goal
Let a `StableLPManager` be owned fractionally by many holders via an ERC-20 share token (a vault),
instead of a single NFT holder. Depositors get shares ∝ their contribution to portfolio value;
redeemers burn shares for stables.

## Why not plain ERC-4626 — why ERC-7575
ERC-4626 is **single-asset**: one immutable `asset()` ERC-20 in, shares out. A `StableLPManager` holds
**several** managed stables across multiple LP positions — there is no single underlying. Forcing 4626
would mean picking one stable as "the asset" and swapping everything else through it (extra slippage,
arbitrary choice).

**ERC-7575** fits: it decouples the share token from the vault and allows **multiple entry assets** —
one share ERC-20, plus a per-stable `Vault` (each advertising its own `asset()` and `share()`), all
minting/redeeming the same shares. That matches "deposit any managed stable."

## Architecture — a non-invasive WRAPPER (do not modify StableLPManager)
A new `StableLPVault` that **holds the singleton ownership NFT** of an existing `StableLPManager` and
issues shares. The manager is untouched (preserves its EIP-170 margin ~604 B and its audit surface).
```
share holders ──shares──> StableLPVault ──owns TOKEN_ID──> StableLPManager ──> V4 pools
                              │  (is the NFT owner ⇒ can call withdrawTo / set operator)
deposit stable ──────────────┘  (routes to allocate/allocateFrom; redeem routes to withdrawTo)
```
- The vault becomes the manager's NFT owner, so it can drive `withdrawTo` for redemptions and manage
  operators. The operator (bot) still drives `allocate`/`reinvest` as today.
- Per ERC-7575, deploy one share token + one `Vault` adapter per managed stable (all share the token).

## The hard problems (why this is NOT trivial)

### 1. NAV / `totalAssets`
Share price = portfolio value / supply. Portfolio value (in a common unit) =
`Σ PositionState.value(principal + fees)` over open positions **+** idle managed-stable balances on the
manager. Cross-stable summation requires a **par assumption** (1 USDC = 1 USDT = 1 DAI = … = 1 unit).
- Reuse `src/lib/PositionState.sol` (view-only) + the manager's `managedStables`/`pools` for the sum
  (the same data `UniLens.managerInfo` already exposes).
- **Risk:** a depeg makes par-NAV wrong → deposit/redeem arbitrage drains honest holders. Mitigations to
  spec: a depeg circuit-breaker (pause if any stable's external price deviates > X bps), or an oracle
  per stable instead of par. Decide tolerance.

### 2. Redemption mechanics (the crux)
Shares must be redeemable, but value is locked in LP positions and a redeem must produce stables:
- **(a) Pro-rata pull on redeem** — pull `shares/supply` of each position via `withdrawTo`. Problem:
  `withdrawTo` needs operator-supplied legs/swaps (off-chain), so a fully on-chain autonomous redeem
  isn't possible without an on-chain router; gas + slippage per redeem.
- **(b) Idle buffer** — keep a % of NAV un-allocated so small redeems pay from the buffer instantly;
  large redeems queue. Simple UX, but idle drag + buffer-runs under stress.
- **(c) Async / request-redeem (ERC-7540 style)** — redeem is a two-step request the operator fulfils
  by pulling liquidity. Cleanest for LP vaults, worst UX.
Recommendation to evaluate: **(b) buffer + (c) async** for the overflow. Pure (a) is likely too fragile.

### 3. First-depositor inflation / donation attack
Classic 4626 share-price manipulation (donate to inflate share price, round the next depositor to 0
shares). Mitigate with OZ virtual-shares / decimals-offset, or a seeded dead-shares mint at init.

### 4. Fee interaction
The 10% protocol fee already skims at the manager level (ERC-6909 → `FeeRedeemer`). The vault may add a
management/performance fee — must be layered on **net** NAV (after protocol fee), and the
`PositionState`-based NAV must not double-count the already-skimmed fees.

### 5. Auth / operator interplay
The vault owns the NFT, so `onlyOwnerNFT` actions (`withdrawTo`, `setOperator`) are vault-internal;
`onlyAuthorized` actions (`allocate`/`reinvest`) stay with the operator bot. Define who can trigger
redemption pulls (vault contract under share-redeem, not an arbitrary caller).

## Open questions (resolve before prototyping)
- Par-NAV vs per-stable oracle? Depeg policy (pause vs price)?
- Redemption model: buffer %, async threshold, who fulfils?
- One vault per manager, or a vault managing a basket of managers?
- Management/perf fee? On whom, accrued how?
- ERC-7575 multi-vault vs a single-asset-canonicalizing 4626 for a v1 MVP?

## Recommendation
Park as an opt-in, **post-MVP** feature. If pursued, prototype the **wrapper vault** (NFT-held) with a
par-NAV from `PositionState` + an idle-buffer redeem, behind a depeg circuit-breaker, and audit it
**separately** from the core manager. Do not bend `StableLPManager` to fit a vault.
