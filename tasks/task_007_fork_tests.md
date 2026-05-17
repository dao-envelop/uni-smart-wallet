# Task 007 — Fork tests against live V4 PoolManager

> Commit ref: `#7`
> Branch: `feature/task-007-fork-tests`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Verification Plan* — Phase 2
> Depends on: tasks 001–005 (006 not strictly required)

## Goal

End-to-end verification that the wallet's settle/take/unlock plumbing works against the *real* `PoolManager` deployed on Base, not the locally-deployed one used in the unit suite. Catches any divergence between the in-test PoolManager and the production contract (compiler settings, optimizations, peripheral library versions).

## Scope (in this task)

1. **`test/UniSmartWallet.fork.t.sol`**:
   - `setUp`: env-gated `vm.envOr("BASE_RPC", string(""))` → empty ⇒ `vm.skip(true, …)` so CI without secrets stays green. Optional pin via `BASE_FORK_BLOCK`.
   - `POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b` (Base mainnet V4, per `script/chain_params.json`).
   - WETH + USDC canonical Base addresses, sorted into `currency0` / `currency1`.
   - Instead of relying on an existing WETH/USDC pool, the test **initializes its own hookless pool with `fee = 100` (0.01%), `tickSpacing = 1`**. The wallet is the sole LP, so all fees from the trader's swaps accrue to it — deterministic and decoupled from production pool state.
   - Deploys `UniSmartWallet(POOL_MANAGER)` (singleton NFT mints to the test contract → drives ops directly).
   - Funds the wallet + a `trader` EOA with WETH + USDC via `deal`; trader pre-approves a `PoolSwapTest` router.
2. **`test_fork_lifecycle_baseWethUsdc`** — open, two swaps (zeroForOne + oneForZero) so fees accrue on both sides, close; assert `openPositionCount == 0`, `positionOf(salt).liquidity == 0`, and both currency balances strictly increased.
3. **`test_fork_pokeCollectsFees`** — open, two swaps, `pokePosition`; assert principal unchanged and both balances increased.
4. **`test_fork_decreasePartial`** — open, one swap, `decreasePosition(salt, 50%)`; assert remaining liquidity and that the registry entry stays.

## Out of scope

- Multi-chain fork matrix (mainnet, Arbitrum, etc.) — add later if needed.
- Gas snapshots / regression baselines — not in spec.
- Property/invariant testing.

## Files to add / change

| Path | Change |
|---|---|
| `test/UniSmartWallet.fork.t.sol` | New file with the 3 fork tests |

## Acceptance

```bash
# Without BASE_RPC — suite skips cleanly:
forge test --match-path test/UniSmartWallet.fork.t.sol -vvv
# With BASE_RPC — three lifecycle tests run:
BASE_RPC=https://... [BASE_FORK_BLOCK=<recent>] \
  forge test --match-path test/UniSmartWallet.fork.t.sol -vvv
```

Full suite still passes: 74 unit tests + 1 fork suite (skipped without env).

## Notes for implementer

- `POOL_MANAGER` address comes from `script/chain_params.json` (chain 8453) — the same file that `DeployWallet` reads. Keep them in sync.
- Initializing our own pool (rather than relying on existing WETH/USDC liquidity on the fork) is what makes the test deterministic. The trader's swaps go through the wallet's lone LP position → fees end up entirely with the wallet.
- `vm.skip(true, reason)` requires forge-std with `Vm.skip(bool, string)` — confirmed available in our pinned version.
- `block.chainid` after `vm.createSelectFork` is the fork's chainId (8453 for Base), so the wallet sees the real chain.
