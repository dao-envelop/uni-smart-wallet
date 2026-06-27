# Task 023 — Standalone deploy script for WalletPositionDescriptor

## Goal

Ship a new `WalletPositionDescriptor` on its own, without re-running the full StableLP stack
(`DeployStableLP.s.sol` would also redeploy the factory/impl/treasury and orphan existing clones).

## Changes

- `script/DeployDescriptor.s.sol` (new): deploys only `WalletPositionDescriptor` (no constructor
  args, no `chain_params.json`), logs the address, and patches the `.descriptor` key in
  `deployments/<chainId>.json` in place (minimal file if none exists). Public `deploy()` is
  side-effect-free for tests; `run()` broadcasts + records. It does **not** call
  `setPositionDescriptor` — wiring stays the documented `cast` step (needs each target's NFT owner).
- `test/DeployDescriptor.t.sol` (new): drives `deploy()` (no broadcast/fs writes); asserts a
  non-zero, distinct descriptor. Rendering is covered by `test/WalletPositionDescriptor.t.sol`.
- `script/README.md`: add a "Deploy the descriptor standalone" subsection and the script to the
  table; tidy the header (drop a stray `=======` marker, move deploy examples to an Examples
  section).

## Notes

- Reuses `vm.exists` + 3-arg `vm.writeJson(json, path, valueKey)` for the in-place single-key
  update — same `deployments/` write target as `DeployStableLP._write`.
