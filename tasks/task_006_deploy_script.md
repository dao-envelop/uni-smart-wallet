# Task 006 — Deploy script

> Commit ref: `#6`
> Branch: `feature/task-006-deploy-script`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Critical Files to Create* (script row)
> Depends on: tasks 001–005 (deploys the finished contract)

## Goal

Reproducible single-wallet deploy via `forge script`, parametrized by env, with a smoke test that exercises the script without a live network.

## Scope (in this task)

1. **`script/DeployWallet.s.sol`**:
   - Imports `forge-std/Script.sol` and the finished `UniSmartWallet`.
   - Reads:
     - `INITIAL_OWNER` (`vm.envAddress`) — recipient of the singleton NFT.
     - `POOL_MANAGER` (`vm.envAddress`) — V4 PoolManager on the target chain.
   - In `run()`: `vm.startBroadcast(); UniSmartWallet w = new UniSmartWallet(IPoolManager(POOL_MANAGER)); vm.stopBroadcast();`
   - `console2.log("UniSmartWallet:", address(w)); console2.log("Owner NFT holder:", w.ownerNFTHolder());`.
   - Note: per the current contract, the singleton NFT is minted to `msg.sender` (the broadcaster). If the spec intent is "mint to `INITIAL_OWNER`", that constructor change belongs to task 001 — assume task 001 already takes `initialOwner` per the spec. If not, the script transfers the NFT in the same broadcast.
2. **Smoke test** `test/DeployWallet.t.sol`:
   - Runs the script in-process via `new DeployWallet().run()` after setting env via `vm.setEnv`.
   - Asserts: wallet code deployed, `ownerNFTHolder() == INITIAL_OWNER`, `POOL_MANAGER` immutable matches.
   - No chain interaction beyond what `vm.startBroadcast` in a local test context allows.

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
forge test --match-path test/DeployWallet.t.sol -vvv
forge script script/DeployWallet.s.sol --rpc-url $RPC --sender $SENDER --account $KEYSTORE_NAME -vvvv  # manual dry-run for the operator
```

Smoke test passes; manual dry-run succeeds against any RPC reachable in the operator's env.

## Notes for implementer

- Prefer `vm.envAddress` over `vm.envOr` here — if the caller forgot to set `POOL_MANAGER`, a clear revert is better than silently deploying with `address(0)`.
- Don't hardcode chain addresses in the script; chain → PoolManager mapping belongs in operator docs.
