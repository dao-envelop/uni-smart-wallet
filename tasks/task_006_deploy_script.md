# Task 006 — Deploy script

> Commit ref: `#6`
> Branch: `feature/task-006-deploy-script`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Critical Files to Create* (script row)
> Depends on: tasks 001–005 (deploys the finished contract)

## Goal

Reproducible single-wallet deploy via `forge script`, parametrized by env, with a smoke test that exercises the script without a live network.

## Scope (in this task)

1. **`script/chain_params.json`** (new) — per-chain parameters keyed by chain ID:
   ```json
   {
     "1":   { "name": "mainnet", "poolManager": "0x…", "initialOwner": "0x…" },
     "10":  { "name": "optimism", "poolManager": "0x…", "initialOwner": "0x…" },
     "8453":{ "name": "base",     "poolManager": "0x…", "initialOwner": "0x…" },
     …
   }
   ```
   Mainnet, Optimism, Unichain (130), Polygon, Base, Arbitrum, Sepolia, Base-Sepolia entries seeded with `address(0)` placeholders — operator fills real addresses before broadcasting (zero values trigger an `InvalidPoolManager` / `InvalidInitialOwner` revert).
2. **`script/DeployWallet.s.sol`**:
   - `run()` resolves `(poolManager, initialOwner)` from `chain_params.json` via `block.chainid`, no env-var plumbing.
   - `loadConfig(path, chainId)` — `vm.readFile` (wrapped in `try/catch` → `ChainConfigMissing` on missing file) + delegate to `parseConfig`.
   - `parseConfig(json, chainId, sourceLabel)` — pure parser. Uses jq-style `.["<chainId>"].field` path (bracket form handles all-digit keys). Reverts: `ChainConfigMissing` when keys absent, `InvalidPoolManager` / `InvalidInitialOwner` on zero addresses.
   - `deployAndAssign(IPoolManager, address)` — public; deploys wallet, reads `ownerNFTHolder()`, transfers NFT if needed. Reads wallet view rather than `msg.sender` to sidestep the script-vs-broadcaster distinction.
3. **`foundry.toml`** — add `fs_permissions = [{access="read", path="./script"}, {access="read-write", path="./test"}]` so script (read) and tests (read-write fixtures) can touch the filesystem.
4. **`test/fixtures/chain_params.test.json`** (committed) — minimal config with one `31337` entry for `loadConfig` integration test.
5. **Tests** `test/DeployWallet.t.sol` — 9 tests:
   - `test_deployAndAssign_sameOwner_skipsTransfer`, `_differentOwner_transfersNFT` — deploy + transfer branches.
   - `test_parseConfig_validEntry`, `_revertsOnMissingChain`, `_revertsOnZeroPoolManager`, `_revertsOnZeroInitialOwner` — pure parser branch coverage via inline JSON.
   - `test_loadConfig_readsFixture`, `_revertsOnUnknownChain`, `_revertsOnMissingFile` — end-to-end with the committed fixture.

## Out of scope

- Multi-wallet factory or CREATE2 deterministic addresses.
- Cross-chain orchestration.
- Etherscan verification step (handled manually with `forge verify-contract` using `[etherscan]` config in `foundry.toml`).

## Files to add / change

| Path | Change |
|---|---|
| `script/DeployWallet.s.sol` | New file |
| `test/DeployWallet.t.sol` | New file, single smoke test |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path "test/*.t.sol" -vvv
# manual dry-run for the operator (no env-vars; reads chain_params.json by chainid):
forge script script/DeployWallet.s.sol --rpc-url $RPC --sender $SENDER --account $KEYSTORE -vvvv
```

74 tests pass (65 from #1–#5 + 9 new in `test/DeployWallet.t.sol`).

## Notes for implementer

- Edit `script/chain_params.json` to add a new chain entry before deploying there. Zero-address placeholders trip the `InvalidPoolManager` / `InvalidInitialOwner` revert by design — fail fast rather than silently deploy with bogus values.
- `msg.sender` inside a forge `Script` is NOT the broadcaster — it's whoever invoked the current function. Use `wallet.ownerNFTHolder()` to find the actual holder after deploy, then transfer from there. The broadcast wrapper ensures `transferFrom`'s msg.sender at the wallet's level IS the broadcaster (= current holder), so the ERC-721 ownership check passes.
- `vm.readFile` / `vm.writeFile` require explicit `fs_permissions` in `foundry.toml`; otherwise forge blocks them.
- Pure-digit JSON keys can't be addressed with the simple dot syntax (`.1.poolManager`) — use bracket form (`.["1"].poolManager`) instead.
