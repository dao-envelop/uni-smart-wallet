# Task 012 — Drop the hook whitelist for a hard hookless-only gate

## Goal

The configurable hook policy (`allowedHooks` mapping + optional external `IHookRegistry` + owner
setters + AND-semantics) was over-engineering: the product has no use case for pools with hooks, and
in `StableLPManager` the whole machinery was dead code — none of its allocate/withdraw/reinvest paths
ever called the check, so the hooks of its 3 configured pools were never validated at all.

Replace the whitelist with a single hard gate: a pool with a non-zero `PoolKey.hooks` is categorically
rejected (`HookNotAllowed`). This keeps the gate's two load-bearing roles intact — it is the only
protection on the exit path (`_withdrawLiquidity` has no slippage cap, and
`afterRemoveLiquidityReturnDelta` hooks could skim withdrawals) and the leash that makes operator
delegation safe (operators open positions under `onlyAuthorized` but can never route into a hooked
pool) — while removing the unused generality and shaving bytecode (EIP-170 headroom).

## Changes

### Contracts
- **`src/abstract/V4PositionManager.sol`** — replace the `_isHookAllowed` whitelist call in
  `_openPosition` with `if (address(key.hooks) != address(0)) revert HookNotAllowed(...)`. Remove the
  `allowedHooks` mapping, `hookRegistry`, `HookAllowed`/`HookRegistrySet` events, the `_isHookAllowed`
  function, and the `IHookRegistry` import. Keep the `HookNotAllowed` error.
- **`src/UniSmartWallet.sol`** — drop the `allowedHooks[address(0)] = true` seed and the
  `setHookAllowed` / `setHookRegistry` setters.
- **`src/StableLPManager.sol`** — drop the seed and setters; **add the real gate in `initialize`**:
  reject any of the 3 configured pools whose `key.hooks != address(0)` (closes the prior validation gap).
- **Delete `src/interfaces/IHookRegistry.sol`** (unused).

### Tests / helpers
- Remove `MockHookRegistry` (`test/helpers/Mocks.sol`) and the hook getters from
  `test/helpers/V4PositionManagerHarness.sol`.
- `test/UniSmartWalletPoolWiring.t.sol` — remove the hook-whitelist / registry-resolution suites and the
  `UniSmartWalletHookHarness`.
- `test/UniSmartWalletOpenPosition.t.sol` — rename the happy-path test to `..._hooklessPool_succeeds`
  (drop the `allowedHooks` assertion). The existing `test_openPosition_disallowedHook_reverts` still
  validates the gate.
- `test/StableLPManagerAllocate.t.sol` — add `test_initialize_hookedPool_reverts`: a config with a
  non-zero hook on one pool reverts `HookNotAllowed` via the factory.

### Docs
- `CLAUDE.md` and `tasks/spec_JITLPWallet.md` (source of truth) updated to the hookless-only policy.

## API surface change (deviation from prior tasks/spec)

Removed public getters `allowedHooks` / `hookRegistry` and functions `setHookAllowed` /
`setHookRegistry` from both `UniSmartWallet` and `StableLPManager`. Acceptable — these contracts are
not yet deployed.

## Result

`StableLPManager` runtime ~23,223 bytes (more EIP-170 margin). All non-fork tests green (90 pass,
fork suite skipped without `BASE_RPC`).

## Verification

- `forge build --sizes`
- `forge fmt --check`
- `forge test` — 90 pass / 1 skipped
- `grep -rn "allowedHooks\|hookRegistry\|IHookRegistry\|_isHookAllowed\|MockHookRegistry" src/ test/` — empty
