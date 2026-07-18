# task_030 — Universal `LPManagerFactory` (replaces `StableLPFactory`)

**Priority:** Medium · **Effort:** M · **Branch:** `task/030-universal-factory` · **Depends on:** task_025 (`BaseLPManager`), task_026 (`VolatileLPManager`)

## Goal
`VolatileLPManager` has no factory — it is only cloned directly via `Clones.clone` in tests, so it
can't be deployed to prod the way Stable is (`StableLPFactory` + `CreateManager.s.sol`). Instead of a
near-duplicate `VolatileLPFactory`, **replace** `StableLPFactory` with one **universal**
`LPManagerFactory` that clones + initializes any `BaseLPManager` product (Stable, Volatile, future)
from a single deployed address.

The two products' `initialize` have **different selectors** (Stable `StablePoolInit[]` with ranges vs
Volatile `PoolKey[]` keys-only), so the factory forwards **raw init calldata** instead of a typed call.

## Decisions (confirmed)
- Universal factory via raw `initData` (not `initialize(bytes)` on the base — that would bloat every
  clone against EIP-170).
- **Owner-mutable allowlist** of blessed implementations (factory is an Envelop-oracle trust anchor).
- **Replace** `StableLPFactory` — migrate all deploy tooling + tests to the one factory.

## Contract — `src/LPManagerFactory.sol` (done)
`is Ownable` (as `FeeRedeemer`). Allowlist `isImplementation`, per-owner `nonce`. `createManager(impl,
expectedOwner, initData)`: allowlist-gate → `cloneDeterministic(keccak(owner, impl, nonce++))` →
low-level `call(initData)` (`InitFailed` on failure) → **post-init check**
`IERC721(clone).ownerOf(TOKEN_ID) == expectedOwner` (`OwnerMismatch`). `predictManagerAddress(impl,
owner, nonce)` and owner-only `setImplementation(impl, allowed)`. No reentrancy guard (impls are
trusted; init moves no value). Reuses `SingletonNFTOwned.TOKEN_ID`, OZ `Clones`/`Ownable`.

## Migration
- Delete `src/StableLPFactory.sol`.
- `script/DeployStableLP.s.sol` — also deploy the Volatile impl; `new LPManagerFactory(admin,
  [stableImpl, volatileImpl])`; JSON gains `volatileImpl` (`impl` stays = stable).
- `script/CreateManager.s.sol` — config `product` field (`stable`|`volatile`); pick impl from the
  deployments JSON; build the product's `InitParams`; `abi.encodeCall(<Product>.initialize, (p))`; call
  `factory.createManager(impl, owner, initData)`.
- `deployments/<chainId>.json` — schema adds `volatileImpl` (new deploys; existing records low-prio).
- `script/README.md` — document the new signature + `product` field.

## Tests
- `test/helpers/FactoryHelper.sol` (new) — shared lib: `single(owner, impl)` builds a one-impl factory;
  `cloneStable(f, impl, p)` encodes + calls `createManager`. Used by every suite (inheriting or not).
- `test/helpers/StableLPTestBase.sol` — `factory` becomes `LPManagerFactory`, cloned via the helper.
- Repoint the standalone `new StableLPFactory(...)` sites (Native, fork, GasCompare, V2, VolatilePool,
  AuditFixes, H2FeeOnTransferPoC, FeeRedeemer) through `FactoryHelper`.
- Rename `test/StableLPFactory.t.sol` → `test/LPManagerFactory.t.sol`: allowlist gating
  (`NotImplementation`), create **both** products, `OwnerMismatch`, `InitFailed`, `setImplementation`
  onlyOwner, `predictManagerAddress`, per-owner nonce, Stable≠Volatile addresses at same nonce.
- `test/DeployStableLP.t.sol` — both impls deploy, factory allowlists both, JSON has `volatileImpl`.

## Gate
- `forge build --sizes` — managers not clone-bound to the factory ⇒ EIP-170 margins unchanged.
- `forge fmt --check`.
- `forge test` — full suite + new factory suite green.
