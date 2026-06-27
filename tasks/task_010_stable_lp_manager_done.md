# Task 010 — StableLPManager + StableLPFactory (allocate + indirect withdrawTo)

## Goal

Build the first product on the V4 base (task 008) + auth base (task 009): a clone-deployed,
NFT-owned manager for stable-pair liquidity (spec: `tasks/spec_StableLPManager.md`).

## Scope (Phase 1)

- `src/StableLPManager.sol` (`is SingletonNFTOwned, SmartWallet, V4PositionManager`), clone-deployed:
  - `initialize(InitParams)` one-shot (custom `_initialized` guard; impl locked in constructor),
    sets PoolManager/QUOTE/3 pools/managed-stable set, seeds hookless pool, mints singleton to owner,
    emits Envelop oracle events. `name()`/`symbol()` are constants (clones skip the ERC721 ctor).
  - Op extension via `_dispatchExtraOp` → `ALLOCATE` / `WITHDRAW_TO` / `REINVEST` (codes 4/5/6).
  - `allocate` (onlyAuthorized): auto-split deposit, swap-then-LP per pool in one unlock, net the
    4-currency set via `TransientStateLibrary.currencyDelta`.
  - `withdrawTo` (onlyOwnerNFT): pull → exactOut-swap → `take(requestedStable, recipient, amount)`
    so the requested stable never lands on the manager/owner balance.
  - `reinvest` (realized `callerDelta`, never `feesAccrued`) + `claimFees` (delegates to base poke).
  - `setPoolConfig` + reused setters / executeEncodedTx / decrease / poke.
- `src/StableLPFactory.sol`: `Clones.cloneDeterministic` per (owner, nonce) + `predictManagerAddress`.
- Small base addition: `_registerSalt` in `V4PositionManager` (reused by allocate/reinvest).
- `PositionMath` converted to a linked (`public`) library to reduce contract size.
- Tests: `StableLPFactory`, `StableLPManagerAllocate`, `StableLPManagerWithdraw` (incl. the
  manager-balance-unchanged invariant), `StableLPManagerReinvest`.

## Out of scope

`WithdrawForwarder` (Phase 2); `reinvestRemainder` on withdraw (field reserved; residuals return
to the manager in Phase 1).

## KNOWN ISSUE — exceeds EIP-170 size limit (RESOLVED in task 011)

As first shipped, `StableLPManager` runtime bytecode was ~28.9 KB, over the 24,576-byte limit.
**Resolved in `tasks/task_011_stable_lp_size.md`** (size now ~23.7 KB, margin ~ +0.9 KB) by dropping
`SmartWallet`, going batch-only for owner calls, and stripping unused base handlers. See task 011 for
the API surface that was trimmed.

## Verification

- `forge build`, `forge fmt --check`.
- `forge test --no-match-path test/*.fork.t.sol` — 98 tests pass (80 prior + 18 new).
- Fork suites compile + skip without `BASE_RPC`.
