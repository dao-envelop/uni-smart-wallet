# Task 019 — MetaStable tokenization spike (doc only)

## Goal
Capture the design + open problems of tokenizing `StableLPManager` LP. Refined in discussion: this is a
step toward a **meta-stablecoin** (metaUSD) backed by *productive* stable-LP collateral — **not** a mere
vault share. **No code**; implementation may be a separate protocol layer entirely.

## Deliverable
`tasks/spec_MetaStable_spike.md` (renamed from `spec_StableLPVault_spike.md`) — covers:
- **Frame:** metaUSD collateralized by stable LP (~par ⇒ tight peg; collateral stays productive, earns V4
  fees).
- **Roles:** *minter* = stable-LP position holder (a distinct role) who locks collateral and mints
  metaUSD and **keeps the LP fees as the mint incentive**; *holder* = uses circulating metaUSD.
- **On-chain hook (minimal):** `encumbered[salt]` mark in the manager; `tokenize` (owner-only) mints;
  burning metaUSD is **folded into `withdrawTo`** (`_pullLiquidity` guard: can't drop liquidity below
  `encumbered` without burning) — owner/minter-only, the only way to free collateral. metaUSD ERC-20 is
  an external contract; EIP-170 budget flagged.
- **Central open problem:** the peg/redemption mechanism (v1 has no holder force-redeem — minter buyback +
  arbitrage only).
- **Alternative (footnote):** ERC-7575 wrapper vault for a later trustless multi-depositor version.

## Status
Spec only. Implementation deferred pending the peg/redemption decision; likely a separate, separately
audited stablecoin layer on top of the core manager.
