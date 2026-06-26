# Task 019 — StableLPManager tokenization spike (doc only)

## Goal
Capture the design + the hard problems of *optionally* tokenizing a `StableLPManager` into fungible
shares, so the team can decide before any prototype. **No code.**

## Deliverable
`tasks/spec_StableLPVault_spike.md` — covers:
- Why **ERC-7575** (multi-asset) over plain ERC-4626 (single-`asset()`), given the manager holds several
  managed stables.
- A **non-invasive wrapper** architecture: a `StableLPVault` that holds the manager's singleton
  ownership NFT and issues shares; the manager is untouched (keeps its EIP-170 margin + audit surface).
- The hard problems: par-based NAV/`totalAssets` (reusing `PositionState`) + depeg risk; redemption
  mechanics (pro-rata pull vs idle buffer vs async ERC-7540); first-depositor inflation attack; fee
  interaction with the existing 10% protocol fee; auth/operator interplay.
- Open questions + a recommendation (post-MVP, prototype + audit separately; don't bend the manager).

## Status
Spike only. Implementation deferred pending sign-off on the open questions.
