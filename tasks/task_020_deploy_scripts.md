# task_020 — Deploy scripts for StableLPManager stack

## Goal

There is no deploy script for the `StableLPManager` product (only `DeployWallet.s.sol` for
`UniSmartWallet`). Add scripts to deploy the full stack and to create a manager.

## Deliverables

1. **`script/DeployStableLP.s.sol`** — deploys the infrastructure, in order:
   1. `FeeRedeemer(poolManager, admin)` — this contract **is** `PROTOCOL_TREASURY`.
   2. `StableLPManager` implementation `(poolManager, address(feeRedeemer))`.
   3. `StableLPFactory(impl)`.
   4. `UniLens()`.
   5. `WalletPositionDescriptor()`.
   - Reads `poolManager` (required, non-zero) and `initialOwner` (optional admin) from
     `script/chain_params.json` keyed by `block.chainid`. If `initialOwner` is zero, the
     broadcaster is used as the `FeeRedeemer` owner (softer than `DeployWallet`, which reverts).
   - Writes addresses to `deployments/<chainId>.json` and logs them.

2. **`script/CreateManager.s.sol`** — clones one manager via the factory from a pool-config JSON
   (`MANAGER_CONFIG` env path, default `script/manager_config.example.json`). Parallel-array config
   shape to avoid struct-decode key-ordering issues.

3. Frontend wiring: copy the emitted addresses into
   `../stablelp-ui/config/deployments.json` (manual, per the agreed flow).

## Notes

- `UniLens` / `WalletPositionDescriptor` have no constructor args.
- `foundry.toml` gains `read-write` fs_permission for `./deployments`.
- `chain_params.json` `initialOwner` is `0x0` for unichain / unichain-sepolia today.
