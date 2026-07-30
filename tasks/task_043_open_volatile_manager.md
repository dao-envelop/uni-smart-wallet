# task_043 — OpenVolatileLPManager: a third implementation, hooks allowed

## Why

A pool with a non-zero hook was rejected unconditionally by one line in the shared base
(`BaseLPManager._registerPool`). That is a product decision the manager owner should be able to make —
hookless should be the **default**, not the only option.

The restriction was not paranoia. It was deliberately narrowed from a whitelist to a categorical reject
in task_012 after audit `2026-05-17` [H-6] (a whitelist is permission-bit blind — approving an address
says nothing about what it may do), [H-7]/[M-7] (a mutable policy can be flipped mid-flight), and [M-3]
(hook-borne re-entry). Audit `2026-07-18` still takes hooklessness as a premise.

So the change is additive: **a third implementation**, not a flag on the existing two and not a relaxed
base.

## Why a separate implementation, and not the two options that were on the table

- **A flag in `InitParams`** would cost storage plus the conditional in *every* manager. `StableLPManager`
  has **482 B** of EIP-170 headroom and `optimizer_runs` is already at 200 (CLAUDE.md claimed 800 —
  a confirmed drift, fixed here), so lowering runs is not an available lever. A new implementation instead
  gets its own 24,576 B budget. A flag also would not, by itself, answer [H-6].
- **Moving the check to the factory** does not work: `LPManagerFactory` forwards an **opaque** `initData`
  (Stable and Volatile have different `initialize` selectors) and cannot decode a `PoolKey`. It would also
  be bypassable — anyone can deploy their own EIP-1167 clone of an implementation and call `initialize`
  directly — so a security invariant would degrade into a convention.

The factory needed **no change at all**: `isImplementation` is an owner-curated allowlist and both the
constructor and `setImplementation` were already n-ary and product-agnostic. "Manual choice" is therefore
"choose this implementation".

## What changed

**`src/BaseLPManager.sol`** — the gate became a per-product predicate:

```solidity
if (!_hooksAllowed() && address(key.hooks) != address(0)) revert HookNotAllowed(address(key.hooks));
...
function _hooksAllowed() internal pure virtual returns (bool) { return false; }
```

Shape chosen by measurement, not taste. The first version was a `_requireHookAllowed(key)` virtual
procedure overridden to an empty body — semantically identical and arguably more idiomatic, but it **cost
Stable and Volatile 9 B each** (24,103 / 23,727), because `virtual` stops solc inlining the single call.
A `pure` predicate is constant-folded per concrete contract instead: `!false && …` compiles back to the
original single comparison and `!true && …` drops the gate entirely. Both existing managers therefore come
out at **exactly** their previous sizes. At 482 B of headroom, 9 B is not free enough to spend on style.

**`src/VolatileLPManager.sol`** — `virtual` added to `ORACLE_TYPE` / `symbol` / `_productName` /
`_defaultName`. They were `override` *without* `virtual`, which terminates the chain and made the contract
uninheritable; one word each.

**`src/OpenVolatileLPManager.sol`** (new, 23,658 B, 918 B headroom) — `is VolatileLPManager`, overrides
`_hooksAllowed() => true` plus the four identity functions (`3002` / `eOpenLP` /
`"OpenVolatileLPManager"` / `"Envelop Open LP Manager"`). `InitParams` and `initialize` are inherited
**verbatim**, which pays off three times: the factory `initData` and init selector are unchanged, the
`CreateManager` volatile config shape works as-is, and `FactoryHelper.cloneVolatile` needed no sibling.

The contract header spells out what the owner accepts, because "hooks allowed" alone would be a
misleading one-liner. Verbatim risks, all verified against current code:

1. A hook with `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` can skim principal undetected — `_pullLiquidity`
   discards the caller `BalanceDelta` entirely, `WithdrawStep` has no `amount*Min`, and the only
   quantitative backstop is the aggregate `AmountNotDelivered` check on what reaches the recipient, so a
   shortfall below that is netted silently by `_settleManaged`. That is [H-6], reachable again by design.
2. A hook that reverts on `beforeRemoveLiquidity` can brick `withdrawTo` and trap the principal.
3. Swap-delta hooks reach the withdraw conversion swaps, which have `sqrtPriceLimitX96` but **no**
   `minAmountOut` and do not pass `_guardSwap`.
4. [M-3] is still open — `unlockCallback` is not `nonReentrant` and its `(op, payload)` is not bound to the
   outer entry point. For the hookless products the gate is what closes the hook-borne variant.
   **Hardening that is its own task and is needed regardless of this one.**

## Tests — `test/OpenVolatileLPManager.t.sol`, 9 tests

Two mock hooks added to `test/helpers/Mocks.sol` on top of v4's `BaseTestHooks`. Note the deployment
wrinkle: v4 reads a hook's permissions from the **low 14 bits of its address**, and
`PoolManager.initialize` rejects a non-zero hook with no flags, so a hook cannot be `new`-ed into place —
`_etchHook` places the runtime code at a crafted address.

- gate lifted: a hooked pool is configured; a hookless one still is; `DuplicatePool` still fires (lifting
  one guard must not lift the others);
- **gate still shut for `VolatileLPManager`** — this closes a pre-existing coverage gap: the hookless gate
  had a test for `StableLPManager` only (`StableLPManagerAllocate.t.sol:94-103`) and none for Volatile;
- identity `3002` / `eOpenLP`, the `EnvelopV2OracleType` emit at impl deploy, and a factory clone carrying
  3002 through `EnvelopV2Deployment`;
- **real ops through a really-installed hook**: allocate → withdraw on a hooked pool, asserting the hook
  was actually invoked on both the add and the remove (and that the seed add went through it, proving the
  hook is installed rather than merely named);
- **the trapped-principal risk as a passing test** (`test_brickingHook_trapsPrincipal`): the deposit is
  accepted, `withdrawTo` reverts, the principal stays stuck. Risk 2 above is demonstrated, not asserted.

## Deploy scripts

`script/DeployStableLP.s.sol` — `openImpl` added to `Flags` / `Existing` / `Deployment`, to
`deployComponents`, to `_readFlags` / `_readExisting` / `_log` / `_write`, and `_implList` /
`_allowlistFreshImpls` widened from two implementations to three.

**Off unless explicitly enabled, including for a chain entry with no `deploy` object.** The legacy
full-set fallback deliberately keeps `openImpl: false`: those configs predate this product and must not
gain it implicitly. `chain_params.json` was therefore left untouched — a missing key already means
`false` via `_optBool`, and `test_readFlags_openImplDefaultsOff` pins that. `deployments/<chainId>.json`
gains an `openImpl` key only on a run that deploys it.

`script/CreateManager.s.sol` — `.product` accepts `"open"`, sharing the volatile init path (same ABI,
different implementation address). While there: an unrecognised `.product` now **reverts
`UnknownProduct`** instead of silently falling back to stable — the same silent-misclassification shape as
the frontend bug below.

New coverage: `test_openImpl_offByDefault_onWhenRequested` (deployed only when asked, correct
treasury/PoolManager wiring, blessed on a fresh factory *alongside* the other two rather than replacing
them) and `test_readFlags_openImplDefaultsOff`.

## Docs

`CLAUDE.md` § Hook policy rewritten from "hookless-only" to a per-product table with the reasoning and the
size note. Architecture section gains the third product. Two confirmed drifts fixed while there:
`optimizer_runs` 800 → 200, and `StableLPFactory` → `LPManagerFactory` (renamed long ago; also the stale
"No factory yet" on Volatile). `tasks/spec_StableLPManager.md` scoped to say hookless is *this* product's
policy. `audits/2026-07-18/AUDIT-REPORT.md` carries an update note where its "хук не может изменить
дельту" premise is stated, since that premise no longer covers all three products.

## Verification

`forge fmt --check` clean. `forge test`: **222 passed, 0 failed, 3 skipped** (was 211 before this task).
`forge build --sizes`:

| Contract | Before | After |
|---|---|---|
| StableLPManager | 24,094 | **24,094** (unchanged) |
| VolatileLPManager | 23,718 | **23,718** (unchanged) |
| OpenVolatileLPManager | — | **23,658** (918 B headroom) |

## Not done, deliberately

- **`VolatileLPTestBase` extraction.** The plan called for factoring the hand-rolled `setUp()` out of
  `VolatileLPManagerAllocate.t.sol` and sharing it. On contact it looked net-negative: it means editing
  three currently-green suites for no functional gain, the shared part is small (PoolManager + routers +
  two tokens + a seed), and this suite needs a materially different setup anyway (hooked key, etched hook,
  no swap router). The new suite is self-contained, matching what all three existing Volatile suites
  already do. Worth doing as its own cleanup if someone adds a fourth Volatile-shaped suite.
- **[M-3] hardening** (`nonReentrant` on `unlockCallback` + binding the in-flight op) — needed
  independently of this task, and it costs bytes in both tight managers, so it deserves its own
  measurement and its own commit.
- **Full frontend support for a third product** (~15 files in `stablelp-ui`) — separate task. What *did*
  ship alongside is the one-line guard so an unknown oracle type can no longer be silently reported as
  "stable"; see that repo's task doc.
