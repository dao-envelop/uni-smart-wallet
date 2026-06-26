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
forge build --sizes               # mirrors CI (`.github/workflows/test.yml`)
forge fmt --check                 # CI fails on unformatted files; use `forge fmt` to fix
forge test -vvv                   # run all tests
forge test --match-test <name> -vvv
forge test --match-path "test/UniSmartWallet*.t.sol" -vvv   # core wallet suites
forge test --match-path test/UniSmartWalletOpenPosition.t.sol -vvv
BASE_RPC=https://... forge test --match-path test/UniSmartWallet.fork.t.sol -vvv  # fork tests, env-gated
```

Deploy:

```bash
forge script script/DeployWallet.s.sol \
  --rpc-url $RPC --sender $SENDER --account $KEYSTORE --broadcast
```

No env vars for deploy params — `DeployWallet` reads `script/chain_params.json` keyed by `block.chainid`. Add a new chain by editing that file (PoolManager addresses come from <https://developers.uniswap.org/contracts/v4/deployments>; `initialOwner` is per-deployment). Zero-address entries fail fast via `InvalidPoolManager` / `InvalidInitialOwner`.

`foundry.toml` enables `ffi = true`, sets `solc = 0.8.26`, `evm = cancun`, `optimizer_runs = 800`, `via_ir = false`, and grants `fs_permissions` for `./script` (read) and `./test` (read-write) so the script and tests can touch `chain_params.json` / fixtures. RPC endpoints and Etherscan keys are wired from env vars — see the `[rpc_endpoints]` / `[etherscan]` blocks.

## Architecture

The repo is the implementation home of **UniSmartWallet**, a contract that fuses three things:

1. **Envelop V2 `SmartWallet` base** (`@envelop-v2/src/impl/SmartWallet.sol`) — provides asset custody, the `ERC721Holder`/`ERC1155Holder` mixins that force the `supportsInterface` override, the inherited `receive() external payable` that accepts native deposits and emits `EtherReceived`, and the `_executeEncodedTx` / `_executeEncodedTxBatch` primitives that the wallet exposes externally (see "Capital flow" below).
2. **OpenZeppelin `ERC721`** — the wallet *is* an NFT contract that mints a **singleton ownership token** (`TOKEN_ID = 1`) at deploy. Whoever holds that one NFT controls the wallet; transferring it atomically hands over wallet control. There is no `Ownable`/admin pattern — the NFT *is* the auth root. The singleton invariant is enforced via the `_update` override: post-constructor mints revert (`SingletonAlreadyMinted`), any burn reverts (`SingletonBurnForbidden`), and ownership transfers auto-clear all operator delegations.
3. **Uniswap V4 direct `PoolManager` integration** — the wallet inherits `IUnlockCallback` and calls `POOL_MANAGER.unlock(...)` itself (no `PositionManager`, no NFT-per-position). Positions are keyed by a caller-chosen `bytes32 salt` (the registry tracks an `_saltIndexPlusOne` map alongside `openSalts` for O(1) splice on close).

The common logic is factored into two shared abstract bases: **`src/abstract/V4PositionManager.sol`** (unlock dispatcher, position registry, swap/settle/take, immutable `POOL_MANAGER`, hookless gate) and **`src/abstract/SingletonNFTOwned.sol`** (singleton-NFT auth + operators). A **second product**, `StableLPManager`, is built on these *same two bases* — see "StableLPManager" below.

### Authorization model

Two modifiers, both keyed off `ownerOf(TOKEN_ID)`:

- `onlyOwnerNFT` — gates everything that can drain capital: `executeEncodedTx`, `executeEncodedTxBatch`, `setOperator`. Operators **must not** get any of these — that would defeat the delegation invariant.
- `onlyAuthorized` — owner-or-operator. Gates the four position primitives (`openPosition` / `closePosition` / `decreasePosition` / `pokePosition`) so the operator's bot can react fast without owner signing every TX.

`setOperator` appends to `_operatorList` on enable and splices it out (swap-and-pop via `_operatorIndexPlusOne`) on disable, so the list holds only *active* operators; the `_update` ERC-721 hook iterates that bounded list on every transfer and resets `operators[*] = false` so the new NFT holder doesn't inherit unexpected delegations (and the per-transfer clear can't be grown into a gas bomb).

### Capital flow

- **Deposits need no wallet-side functions.** ERC-20 has no receiver hook — `IERC20.transfer(walletAddress, amount)` updates the balance and the token's own indexed `Transfer` event is sufficient for indexers. Native deposits work via the inherited `SmartWallet.receive()`.
- **Withdrawals and arbitrary calls go through `executeEncodedTx` / `executeEncodedTxBatch`.** Thin `onlyOwnerNFT` wrappers around the parent's `_executeEncodedTx*`. `withdrawNative` ≡ `executeEncodedTx(payable(to), amount, "")`; `withdrawERC20` ≡ `executeEncodedTx(token, 0, abi.encodeCall(IERC20.transfer, (to, amount)))`. The owner also gets claim-airdrop, approve-spender, and dApp-call for free. Parent's `fixEtherBalance` modifier emits `EtherBalanceChanged` on any value movement.

### V4 unlock callback dispatcher

`unlockCallback(bytes)` is the single entry point from PoolManager. It enforces `msg.sender == POOL_MANAGER` (revert `NotPoolManager`) then decodes a leading `Op` enum (`OPEN | CLOSE | DECREASE | POKE`) and dispatches to the matching internal handler:

- `_handleOpen` — `modifyLiquidity(+L)` → enforce `amount0Max` / `amount1Max` slippage → `Currency.settle` for both currencies from wallet balance → write `positions[salt]` → push `openSalts` + `_saltIndexPlusOne[salt]`.
- `_handleClose` / `_handleDecrease` / `_handlePoke` share a `_withdrawLiquidity` helper: `modifyLiquidity(-deltaLiquidity)` → take both currencies to the wallet → return `(owed0, owed1, fees0, fees1)`. Close additionally deletes `positions[salt]` and splices `openSalts` (O(1) via `_saltIndexPlusOne`); decrease subtracts liquidity (entry stays in registry); poke uses `deltaLiquidity == 0` so only fees come back.

`PositionMath` (`src/lib/PositionMath.sol`) provides tick-spacing snapping, `requireValidTickRange`, and a thin pass-through to v4-periphery's `LiquidityAmounts.getLiquidityForAmounts`.

### Pool selection & hook policy

`openPosition` consumes a full `PoolKey` (operator discovers off-chain — Trading API `/quote` or V4 subgraph). On-chain validation, cheapest revert first:

1. `positions[salt].liquidity == 0` (salt collision).
2. `liquidity > 0`.
3. Hookless-only: `address(key.hooks) != address(0)` ⇒ revert `HookNotAllowed`. There is no configurable whitelist/registry — pools with hooks are categorically rejected. (`StableLPManager` enforces the same gate on every configured pool in `initialize`.)
4. `getSlot0(poolId).sqrtPriceX96 != 0` — catches operator typos that would otherwise resolve to a phantom uninitialized pool.
5. Optional `getLiquidity(poolId) >= minPoolLiquidity`.
6. `PositionMath.requireValidTickRange`.

The hook gate is the most security-load-bearing check: hooks with `afterAddLiquidityReturnDelta` / `afterRemoveLiquidityReturnDelta` can skim LP principal/fees (the exit path `_withdrawLiquidity` has no slippage cap), and it is the leash that makes operator delegation safe — operators open positions under `onlyAuthorized` but can never route into a hooked pool. The product has no need for hooked pools, so the gate is a hard `hooks == address(0)` rather than a whitelist.

### Envelop oracle compatibility

The constructor emits `EnvelopV2OracleType(ORACLE_TYPE=2002, ...)` and `EnvelopWrappedV2(...)`. These exist purely so existing Envelop V2 oracles index this contract. Do **not** rename or drop them without coordinating with the Envelop side.

### On-chain metadata (`tokenURI`)

The wallet's `tokenURI(1)` renders the **portfolio of open positions** on-chain. It mirrors Uniswap's `PositionManager → IPositionDescriptor` split, adapted to a singleton-portfolio NFT (one token owns N salt-keyed positions, not one NFT per position):

- `tokenURI` delegates to an external `IWalletDescriptor` set via `setPositionDescriptor` (owner-only). Zero address ⇒ returns `""` (never reverts). Rendering bytecode lives in the descriptor, **not** the wallet — mandatory for EIP-170 (the clone-deployed `StableLPManager` shares the same constraint).
- `src/WalletPositionDescriptor.sol` iterates `openSalts`, values each position via `src/lib/PositionState.sol`, and emits a base64 `data:application/json` blob (per-position principal + uncollected fees + a simple SVG summary card).
- `PositionState.value` is **view-only** (no `unlock`): principal via `SqrtPriceMath`, fees via `StateLibrary.getPositionInfo` (last) vs `getFeeGrowthInside` (now) — `fees = liquidity * ΔfeeGrowthInside / 2**128`. V4 has no `tokensOwed`; fees live entirely in feeGrowth.
- **ERC-4906**: every position mutation (`openPosition`/`closePosition`/`decreasePosition`/`pokePosition`; `allocate`/`withdrawTo`/`reinvest`/`claimFees` on the manager) emits `MetadataUpdate(TOKEN_ID)` so marketplaces refresh. `supportsInterface` advertises `0x49064906`.

### StableLPManager (second product)

`src/StableLPManager.sol` is a separate product on the **same two bases** (`V4PositionManager` + `SingletonNFTOwned`): a **factory-cloned**, NFT-owned manager for a *configured set* of hookless stable pools. It is deployed as an **EIP-1167 clone** via `src/StableLPFactory.sol` (atomic `initialize`; the impl constructor locks itself and sets the immutable `POOL_MANAGER` + `PROTOCOL_TREASURY`). It drops Envelop's `SmartWallet` (ERC20-only custody + a single `executeEncodedTxBatch` hatch) to fit under EIP-170.

- **Positions keyed `salt == poolId`** — one per pool; `_poolIndexPlusOne` gives O(1) `poolId → config` lookup *and* the init-time duplicate-pool guard. `managedStables` is the deduped union of all pool currencies.
- **Ops:** `allocate` (auto: deploy idle balance) / `allocateFrom` (manual: a named just-deposited stable, snapshot-guarded so only it is drawn down), `withdrawTo` (indirect drain — deliver any managed stable straight to a recipient via `take`, never landing on the manager/owner balance), `reinvest` (compound), `claimFees` (poke harvest). `allocate`/`reinvest` legs carry **no `amount*Max`** (owed ≤ `amount*Desired`; `minLiquidity` is the slippage floor) — unlike `UniSmartWallet.openPosition`, which keeps `amount*Max` (caller passes a fixed `liquidity`, so owed is price-dependent).
- **Protocol fee:** a constant 10% (`PROTOCOL_FEE_BPS`) of every realized fee accrual, skimmed at each fee-realizing `modifyLiquidity` as **ERC-6909 claims** (`take(...,true)`) to the immutable `PROTOCOL_TREASURY` — principal is never taxed; the treasury redeems via `unlock→burn→take`.
- **Auth:** `onlyOwnerNFT` (`withdrawTo`, `executeEncodedTxBatch`, `setOperator`, `setPositionDescriptor`) vs `onlyAuthorized` (`allocate` / `allocateFrom` / `reinvest` / `claimFees`).
- Native-ETH pools are supported (native = `Currency(address(0))`).

Full spec: `tasks/spec_StableLPManager.md`; per-op asset/delta diagrams: `tasks/StableLPManager_flows_ru.md`; audit: `AUDIT-REPORT.md`.

### Submodules and remappings

Solidity dependencies are pulled via git submodules under `lib/` (`forge-std`, `envelop-protocol-v2`, `v4-hooks-public`). The bulk of `remappings.txt` re-exports paths *through* `v4-hooks-public` — meaning OZ, Uniswap v2/v3/v4 core/periphery, Permit2, Solady, etc. all resolve into nested subdirectories of `lib/v4-hooks-public/lib/...`. Two top-level remappings to know:

- `@envelop-v2/` → `lib/envelop-protocol-v2/`
- `@openzeppelin/contracts/` → `lib/v4-hooks-public/lib/openzeppelin-contracts/contracts/` (do **not** add a separate OZ submodule — use the one bundled under v4-hooks-public)
- `@uniswap/v4-core/`, `@uniswap/v4-periphery/` — V4 core types (`PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `ModifyLiquidityParams`), `IPoolManager`, `IUnlockCallback`, `StateLibrary`, `TickMath`. Test utilities live under `@uniswap/v4-core/test/utils/` (`CurrencySettler`) and `@uniswap/v4-core/src/test/` (`PoolSwapTest`, `PoolModifyLiquidityTest`, mock hooks).

If you add a new dependency, add it as a submodule and extend `remappings.txt`; don't introduce a parallel OZ/Uniswap copy.

## Test layout

Tests are split by concern; each file boots only the scaffolding it needs:

| File | Boots | Covers |
|---|---|---|
| `test/UniSmartWallet.t.sol` | wallet only | auth, operators, singleton invariant, `executeEncodedTx*` |
| `test/UniSmartWalletPoolWiring.t.sol` | wallet + placeholder PoolManager | constructor wiring, `unlockCallback` gating, views |
| `test/UniSmartWalletOpenPosition.t.sol` | `V4WalletTestBase` (real PoolManager + 2 tokens + initialized pool + funded wallet) | full `openPosition` paths |
| `test/UniSmartWalletExitPositions.t.sol` | `V4WalletTestBase` + `PoolSwapTest` router + funded trader | `closePosition` / `decreasePosition` / `pokePosition`, fee accrual via real swaps, multi-salt registry consistency |
| `test/PositionMath.t.sol` | none | library branch coverage via a `PositionMathWrapper` (library calls are inlined, so `vm.expectRevert` can't see them without an external boundary) |
| `test/PositionState.t.sol` | `V4WalletTestBase` + `PoolSwapTest` | `PositionState.value` principal/fee math via a `PositionStateWrapper` (fees asserted after real swaps) |
| `test/WalletPositionDescriptor.t.sol` | `V4WalletTestBase` + `PoolSwapTest` | `tokenURI` data-URI rendering (empty + populated portfolio), descriptor setter auth, ERC-4906 `MetadataUpdate` emits, `supportsInterface` |
| `test/DeployWallet.t.sol` | `DeployWallet` script | `deployAndAssign` + `parseConfig` (inline JSON) + `loadConfig` (committed fixture under `test/fixtures/`) |
| `test/UniSmartWalletNativePosition.t.sol` | PoolManager + native pool | open/close/operator position in an `ETH/token` pair (native settle/take) |
| `test/V4PositionManager.t.sol` | `V4PositionManagerHarness` | base `_openPosition` validation + `unlockCallback` dispatch in isolation |
| `test/StableLP*.t.sol` | `StableLPTestBase` (factory + configured pools) | see grouped note below |
| `test/UniSmartWallet.fork.t.sol` | live PoolManager via fork | end-to-end against real V4 on Base, env-gated by `BASE_RPC` |

**StableLPManager suites** (`test/StableLP*.t.sol`, most inherit `test/helpers/StableLPTestBase.sol`): `StableLPFactory` (clone+`initialize`, dup/bounds, name/symbol constants), `StableLPManagerV2` + `StableLPManagerAllocate` (managed-stable union, `allocate`/`allocateFrom` + snapshot guard, multi-pool), `StableLPManagerWithdraw` (indirect-drain `withdrawTo`), `StableLPManagerReinvest` (`reinvest`/`claimFees`), `StableLPManagerProtocolFee` (exact 90/10 split, ERC-6909 skim, zero-treasury revert), `StableLPManagerAuditFixes` (operator splice/churn, uninitialized-pool guard), `StableLPManagerNative` (ETH-pair allocate + withdrawTo).

Shared helpers in `test/helpers/`:

- `Mocks.sol` — `MockERC20`, `Echo`. **Add new mocks here**, don't redefine inline.
- `V4WalletTestBase.sol` — abstract `Test` base that deploys PoolManager + sorted MockERC20 pair + hookless pool + funded wallet. Any new test that needs the wallet wired to a real PoolManager should inherit from this.
- `StableLPTestBase.sol` — abstract base for the manager suites: deploys PoolManager + impl + `StableLPFactory`, creates a clone with a multi-pool stable config, funds it, exposes `_allocateParams`/`_initParams` helpers. `V4PositionManagerHarness.sol` exposes the base `_openPosition` for `V4PositionManager.t.sol`.

One test harness lives inline next to the suite that uses it:

- `UniSmartWalletMintHarness` — exposes internal `_mint` / `_burn` to verify the singleton invariant reverts.

## Task and branch workflow

See `AGENTS.md`: every task lives in `tasks/task_NNN.md`, is solved on a new branch, and the leading 3-digit number becomes `#<n>` in the commit message. Confirm which task file to work on **before** starting. Branch each task off the previous one (the chain `master → #1 → #2 → … → #7` keeps merges sequential and small).

Spec sources of truth (actualized to the implemented contracts): **`tasks/spec_JITLPWallet.md`** for `UniSmartWallet`, **`tasks/spec_StableLPManager.md`** (+ `tasks/StableLPManager_flows_ru.md` asset/delta diagrams) for `StableLPManager`. Read the relevant one before touching the contract; per-task history lives in `tasks/task_NNN_*.md`.
