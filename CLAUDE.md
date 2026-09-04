# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Commands

Foundry-based project. Submodules must be initialized before anything builds:

```bash
git submodule update --init --recursive
```

Day-to-day:

```bash
forge build --sizes               # mirrors CI (`.github/workflows/test.yml`); managers must stay < 24,576 B
forge fmt --check                 # CI fails on unformatted files; use `forge fmt` to fix
forge test -vvv                   # run all tests
forge test --match-test <name> -vvv
forge test --match-path "test/StableLP*.t.sol" -vvv          # StableLPManager suites
forge test --match-path test/VolatileLPManagerAllocate.t.sol -vvv
BASE_RPC=https://... forge test --match-path "test/*.fork.t.sol" -vvv   # fork tests, env-gated
```

Deploy (StableLP stack + a manager clone):

```bash
forge script script/DeployStableLP.s.sol --rpc-url $RPC --sender $SENDER --account $KEYSTORE --broadcast
MANAGER_CONFIG=script/my_pools.json forge script script/CreateManager.s.sol \
  --rpc-url $RPC --sender $SENDER --account $KEYSTORE --broadcast
```

`DeployStableLP` reads `script/chain_params.json` keyed by `block.chainid` (PoolManager address per chain,
from <https://developers.uniswap.org/contracts/v4/deployments>); addresses are written to
`deployments/<chainId>.json`. See `script/README.md`.

`foundry.toml` enables `ffi = true`, sets `solc = 0.8.26`, `evm = cancun`, `optimizer_runs = 200`,
`via_ir = false`, and grants `fs_permissions` for `./script` and `./test`.

## Architecture

The repo implements **NFT-owned Uniswap V4 LP managers** that interact with the `PoolManager` directly
(no v4 `PositionManager`, no NFT-per-position). Three products share three abstract bases:

**Bases (`src/abstract/` + `src/BaseLPManager.sol`):**

1. **`V4PositionManager`** — config-agnostic V4 layer: the `PoolManager.unlock` dispatcher shell
   (`unlockCallback` → `_dispatchExtraOp`), the swap/settle/take primitives (`_swap` / `_settle` /
   `_take` / `_takeClaim`), the salt registry (`openSalts` + `_saltIndexPlusOne`, O(1) splice), and the
   canonical **`Position` view type** + an abstract `positionOf`. It owns **no** position storage.
2. **`SingletonNFTOwned`** — singleton-NFT auth: the wallet *is* an ERC-721 that mints one ownership
   token (`TOKEN_ID = 1`); whoever holds it controls the manager. `onlyOwnerNFT` vs `onlyAuthorized`
   (owner-or-operator); the `_update` hook clears operator delegations on transfer.
3. **`BaseLPManager` (`is SingletonNFTOwned, V4PositionManager`)** — the configured hookless pool set
   (identity only: `PoolConfig { PoolKey key }`), the managed-currency union, the init scaffolding
   (`_beginInit` / `_registerPool` / `_finishInit`), the constant 10% protocol-fee skim (ERC-6909
   claims to the immutable `PROTOCOL_TREASURY`), settlement helpers, `tokenURI`/descriptor, the
   owner escape hatch (`executeEncodedTxBatch`), and the **position store**. Positions are stored as
   `StoredPosition { PoolId poolId; int24 tickLower; int24 tickUpper; uint128 liquidity; uint64 openedAt }`
   (2 slots) — the full `PoolKey` is **reconstructed from the configured set** in `positionOf`
   (`pools[_indexOf(poolId)].key`), so no key is stored on-chain.

**Products:**

- **`StableLPManager`** (`src/StableLPManager.sol`) — configured set of hookless stable pools.
  **`salt == poolId`** (one position per pool), each position held between **fixed bounds** recorded in
  `rangeOf[poolId]` at `initialize` — product policy, not a property of the pool (a pool has liquidity
  and a price; a range belongs to a position).
  Deployed as an **EIP-1167 clone** via **`LPManagerFactory`** (atomic `initialize`).
  Ops: `allocate` / `allocateFrom` (snapshot-guarded) / `withdrawTo` (indirect drain via `take`) /
  `reinvest` / `claimFees`. `allocate`/`reinvest` carry no `amount*Max` (owed ≤ desired at the on-chain
  price; `minLiquidity` is the floor). `InitParams.pools` is `StablePoolInit[] { key, tickLower, tickUpper }`.
- **`VolatileLPManager`** (`src/VolatileLPManager.sol`) — arbitrary/volatile pairs. **`salt ≠ poolId`**:
  a pool holds **many positions** (each a caller-chosen salt) at **per-call ranges**; the position
  records its `poolId`. Adds `minAmountOut` on the balancing pre-swap, `recenter` (single-call
  remove→swap→re-add within one pool), `moveLiquidity` (the same across two pools, task_051), and an
  external `IPriceOracle` guard (`setPriceOracle`) that gates **operator**
  swaps fail-closed (owner swaps bypass; see Authorization model). Like Stable,
  the add is sized from desired amounts with a `minLiquidity` floor — no `amount*Max` (owed ≤ desired
  by construction). `InitParams.pools` is `PoolKey[]` (keys only — ranges are per-call). Cloned through
  the same `LPManagerFactory`.
- **`OpenVolatileLPManager`** (`src/OpenVolatileLPManager.sol`, task_043) — `VolatileLPManager` with the
  hook gate lifted (`_hooksAllowed() => true`), `ORACLE_TYPE 3002`, symbol `eOpenLP`. Everything else,
  including `initialize`/`InitParams` and therefore the factory `initData` and the init selector, is
  inherited **verbatim** — only the implementation address differs, so `FactoryHelper.cloneVolatile` and
  the `CreateManager` volatile config shape both work unchanged. See **Hook policy** for what choosing it
  costs.

### Authorization model

`onlyOwnerNFT` gates capital-draining entry points (`withdrawTo`, `executeEncodedTxBatch`, `setOperator`,
`setPositionDescriptor`, `setPriceOracle`). `onlyAuthorized` (owner-or-operator) gates the position ops
(`allocate`/`allocateFrom`/`reinvest`/`claimFees`; volatile `recenter`) so an operator bot can act fast
without owner signing every TX. Operators cannot withdraw (no `withdrawTo`/escape hatch). They also cannot
bleed value through an adverse swap: any **operator-triggered** swap in either product (Stable
`allocate`/`reinvest` pre-swaps, Volatile `allocate`/`recenter`) is gated by the shared `priceOracle`
(in `BaseLPManager`) and **fail-closed** — it reverts unless the oracle vouches for the realized price
(audit `2026-07-18` H-VOL-1 / M-VOL-2, task_031 + task_032). The **NFT owner keeps full freedom** — owner
swaps bypass the oracle. (Stable has no operator-callable principal-removal path, so its operator exposure
was idle+fees, not principal; Volatile's `recenter` frees principal, hence the HIGH there.)

### Hook policy

**Per product**, decided by `BaseLPManager._hooksAllowed()` and applied in `_registerPool` at init only
(an operator can only ever name a `PoolId` already in the configured set, never a raw key):

| Product | `_hooksAllowed()` | Behaviour |
|---|---|---|
| `StableLPManager`, `VolatileLPManager` | `false` (base default) | a non-zero hook reverts `HookNotAllowed` at init |
| `OpenVolatileLPManager` | `true` (override) | any pool is accepted, hooked or not |

The default is a hard `hooks == address(0)`, not a whitelist: a whitelist was tried and removed
(task_012) because approving an address says nothing about its permission bits — audit `2026-05-17`
[H-6]. Keeping it categorical also keeps [H-7]/[M-7] answered, since there is no setter and the decision
is a property of the implementation a clone points at.

Why the default is load-bearing rather than merely cautious: the **exit path has no floor**.
`_pullLiquidity` discards the caller `BalanceDelta` entirely, `WithdrawStep` carries no `amount*Min`, and
the only quantitative backstop is the aggregate `AmountNotDelivered` check on what reaches the recipient
— so a hook with `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` can skim principal and `_settleManaged` nets the
shortfall silently. Audit `2026-07-18` still takes hooklessness as a premise **for those two products**.

`OpenVolatileLPManager` (task_043, `ORACLE_TYPE 3002`) exists because forbidding hooked pools outright is
a product decision the owner should be able to make. It is a separate implementation rather than a flag:
each implementation gets its own EIP-170 budget (Stable has ~482 B left), and the factory's owner-curated
`isImplementation` allowlist already makes choosing it the explicit opt-in. For that product the
invariant "the manager's own code protects the principal" **does not hold** — it holds as far as the
chosen hook is honest. `test/OpenVolatileLPManager.t.sol` demonstrates that with a passing test
(`test_brickingHook_trapsPrincipal`), not just a comment. Hookless Volatile stays the default a UI offers
first.

`_hooksAllowed()` is shaped as a `pure` predicate rather than a virtual gate procedure so solc
constant-folds it per contract: Stable and Volatile compile byte-for-byte the size they were. The
procedure form cost each of them 9 B, which is too much at 482 B of headroom.

### Unlock dispatch

`unlockCallback` enforces `msg.sender == POOL_MANAGER`, decodes a leading `(uint8 op, bytes payload)`,
and forwards to the product's `_dispatchExtraOp`. Canonical `Op.POKE` (= claimFees) plus product op
codes: Stable `ALLOCATE=4 / REINVEST=6`; Volatile `ALLOCATE_V=7 / RECENTER=8 / MOVE=9`. `WITHDRAW_TO=5`
is owned by the base for both products (task_029) — there is no `WITHDRAW_TO_V`, and this file used to
say otherwise (audit `2026-07-18` I-DOC-1). `_pokeFromConfig(salt)` (in `BaseLPManager`) reconstructs the pool key from config and
routes `Op.POKE` to the product handler. `PositionMath` (`src/lib/PositionMath.sol`) does tick-range
validation + `liquidityFromAmounts`.

### On-chain metadata (`tokenURI`)

`tokenURI(1)` renders the open-position portfolio via an external `IWalletDescriptor` set through
`setPositionDescriptor` (owner-only; zero ⇒ returns `""`, never reverts). Rendering bytecode lives in
`src/WalletPositionDescriptor.sol` (EIP-170 — the clone-deployed managers can't carry it). It iterates
`openSalts`, reads each position via `positionOf`, and values it with `src/lib/PositionState.sol`
(view-only: principal via `SqrtPriceMath`, fees via feeGrowth deltas — V4 has no `tokensOwed`). Every
position mutation emits ERC-4906 `MetadataUpdate(TOKEN_ID)`; `supportsInterface` advertises `0x49064906`.

### Read aggregator

`src/UniLens.sol` (stateless) returns the full open-position portfolio (`positionOf` + `PositionState`
valuation) + manager config + idle balances in one call, for frontends. Product-agnostic.

### Envelop oracle compatibility

`_finishInit` emits `EnvelopV2OracleType(ORACLE_TYPE, ...)` (Stable 3000, Volatile 3001) and
`EnvelopWrappedV2(...)` so existing Envelop V2 oracles index the manager. Do **not** rename/drop them
without coordinating with the Envelop side.

### Submodules and remappings

Dependencies are git submodules under `lib/`. `remappings.txt` re-exports most paths *through*
`lib/v4-hooks-public/lib/...` (OZ, Uniswap v4 core/periphery, Permit2, Solady). Two to know:
`@envelop-v2/` → `lib/envelop-protocol-v2/`; `@openzeppelin/contracts/` →
`lib/v4-hooks-public/lib/openzeppelin-contracts/contracts/` (do **not** add a separate OZ submodule).
Note: Envelop's `SmartWallet` (`@envelop-v2/src/impl/SmartWallet.sol`) is a *different* contract from
these managers — the managers do **not** inherit it (ERC20-only custody + a batch escape hatch instead).

## Test layout

Tests split by concern; each boots only what it needs. Shared helpers in `test/helpers/`:

- `Mocks.sol` — `MockERC20`, `Echo`. **Add new mocks here.**
- `StableLPTestBase.sol` — deploys PoolManager + impl + `LPManagerFactory`, clones a multi-pool stable
  manager, funds it; `_initParams` / `_saltFor` helpers. Most `StableLP*` suites inherit it.
- `V4PositionOpsHarness.sol` — **test-only** mixin that restores a standalone open/close/decrease/poke
  lifecycle on `V4PositionManager` (removed from production when the JIT-LP wallet was retired). It keeps
  its **own** full-`Position` storage (arbitrary keys, no config to reconstruct from) and implements
  `positionOf`. `V4PositionManagerHarness.sol` is the ungated concrete subclass (+ a swap-then-add op).
- `NFTPositionHarness.sol` — NFT-owned harness (auth + descriptor + the standalone lifecycle) driving
  the descriptor / lens / PositionState suites.

| Suite | Covers |
|---|---|
| `test/StableLP*.t.sol` | factory clone+init, allocate/allocateFrom + snapshot guard, withdrawTo, reinvest/claimFees, protocol-fee 90/10 split, audit fixes, native-ETH pools, volatile-pool-degradation justification |
| `test/VolatileLPManagerAllocate.t.sol` | allocate (multi-position/pool, range-mismatch, amountMax, minAmountOut), recenter (+rebalance swap), withdrawTo, claimFees |
| `test/V4PositionManager.t.sol` | base mechanics via `V4PositionManagerHarness` |
| `test/WalletPositionDescriptor.t.sol` / `test/UniLens.t.sol` / `test/PositionState.t.sol` | `tokenURI` rendering, lens output, position valuation (via the NFT/ops harness) |
| `test/PositionMath.t.sol` | library branch coverage via a wrapper |
| `test/DeployStableLP.t.sol` / `test/LPManagerFactory*.t.sol` / `test/FeeRedeemer.t.sol` | deploy script, factory, treasury redeemer |
| `test/OpenVolatileLPManager.t.sol` | the hooks-allowed product: gate lifted, gate still shut for Volatile, real ops through an installed hook, the trapped-principal risk |
| `test/*.fork.t.sol` | live V4 on Base, env-gated by `BASE_RPC` |

## Task and branch workflow

See `AGENTS.md`: every task lives in `tasks/task_NNN.md`, is solved on a new branch, and the leading
3-digit number becomes `#<n>` in the commit message. Confirm which task file to work on **before**
starting. Spec sources of truth: **`tasks/spec_StableLPManager.md`** (+ `tasks/StableLPManager_flows_ru.md`
asset/delta diagrams). Per-task history lives in `tasks/task_NNN_*.md`.

> **Rely on the code, not this file, when planning refactors.** `UniSmartWallet` (the original JIT-LP
> wallet) was removed in task_025; grep `src/` before assuming a contract exists.
