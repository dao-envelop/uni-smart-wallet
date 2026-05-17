# Task 007 — Fork tests against live V4 PoolManager

> Commit ref: `#7`
> Branch: `feature/task-007-fork-tests`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Verification Plan* — Phase 2
> Depends on: tasks 001–005 (006 not strictly required)

## Goal

End-to-end verification that the wallet's settle/take/unlock plumbing works against the *real* `PoolManager` deployed on Base, not the locally-deployed one used in the unit suite. Catches any divergence between the in-test PoolManager and the production contract (compiler settings, optimizations, peripheral library versions).

## Scope (in this task)

1. **`test/UniSmartWallet.fork.t.sol`**:
   - `setUp`: `vm.createSelectFork(vm.envOr("BASE_RPC", string("")));`. If empty → `vm.skip(true)` to make the suite a no-op when env isn't set (CI without secrets stays green).
   - Pin a recent Base block via `vm.envOr("BASE_FORK_BLOCK", uint256(0))` so behaviour is reproducible.
   - Wire constants for Base V4 deployment: `POOL_MANAGER`, the WETH/USDC `PoolKey` (currencies, fee, tickSpacing, hooks = address(0)).
   - Deploy `UniSmartWallet(initialOwner=address(this), POOL_MANAGER)`; fund it with WETH + USDC via `deal`.
2. **`test_fork_lifecycle_baseWethUsdc`**:
   - `openPosition` around the current tick with a non-zero amount.
   - Use a second EOA (`vm.startPrank`) + `PoolSwapTest` (or direct router call) to swap through the range — generates fees.
   - `closePosition` and assert the wallet got back **principal + fees > principal**.
3. **`test_fork_pokeCollectsFees`**: open, swap, `pokePosition`, assert fee balances increased without losing principal.
4. **`test_fork_decreasePartial`**: open, swap, `decreasePosition` for 50%, assert state and balances.

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
BASE_RPC=https://... BASE_FORK_BLOCK=<recent> \
  forge test --match-path test/UniSmartWallet.fork.t.sol -vvv
```

All 3 fork tests pass. With `BASE_RPC` unset the suite skips cleanly (no failure).

## Notes for implementer

- Real Base V4 `PoolManager` address: confirm via the Uniswap deployments page before pinning. Do **not** guess; addresses live in `tasks/spec_JITLPWallet.md` references and the Uniswap docs.
- The `hooklist` registry cross-check mentioned in the spec is off-chain — for the fork test, pick a hookless pool (`hooks = address(0)`) so `allowedHooks` default seeding works without `setHookAllowed`.
- Keep block-pinning aggressive — fork tests against `latest` are non-deterministic and break CI.
