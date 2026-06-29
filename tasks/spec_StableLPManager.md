# StableLPManager — Multi-Pool Stable LP Manager with Indirect Withdraw

> **Status:** Implemented (master `be22a2c`). This document describes the contract **as built** (the
> v2 model). The original draft (single `QUOTE`, weights, three fixed pools) is gone — see the
> changelog refs at the bottom for the task history. Asset/delta movement per operation is diagrammed
> in **`StableLPManager_flows_ru.md`**; the security audit is in **`AUDIT-REPORT.md`**.
> **Sibling:** `spec_JITLPWallet.md` — the tactical single-wallet `UniSmartWallet` (arbitrary pool per
> `openPosition`). `StableLPManager` is a different product: a factory-cloned, NFT-owned manager over a
> *configured* set of stable pools, with a protocol fee and indirect withdraw.
> **Shared base:** `src/abstract/V4PositionManager.sol` (unlock dispatcher, position registry,
> swap/settle/take, hookless gate) + `src/abstract/SingletonNFTOwned.sol` (auth).

## Concept

A **clone-deployed, NFT-owned position manager** for **stable liquidity** across an **arbitrary,
configurable set of hookless Uniswap V4 pools** (1..`MAX_POOLS = 8`; *no* common hub/quote stable
required). An EOA mints an instance from `StableLPFactory`, supplying the pool set at `initialize`.
Thereafter:

- The owner deposits **any** managed stable (a currency that appears in some configured pool); native
  ETH is supported (`Currency(address(0))`).
- An **operator** (or the owner) drives liquidity with `allocate` (auto: deploy whatever sits on
  balance) or `allocateFrom` (manual: deploy a specific just-deposited stable, guarded). Each *leg* is
  fully described off-chain: target pool, optional pre-swap, desired add amounts, slippage floor.
- The owner periodically harvests (`claimFees`) or compounds (`reinvest`), and — the headline feature
  — issues an **indirect withdraw** (`withdrawTo`): deliver any managed stable to an **arbitrary
  recipient** under the invariant:

  > **The requested stable never lands on the ERC-20/native balance of the manager or the owner during
  > the withdraw.** It exists only as a transient PoolManager delta, delivered straight to the recipient.

- A **protocol fee (10%)** is skimmed from every realized fee accrual to an immutable treasury (see
  *Protocol fee*).

**Key contrasts vs `UniSmartWallet`:**

| | UniSmartWallet | StableLPManager |
|--|----------------|-----------------|
| Creation | one contract per `new` deploy | EIP-1167 clone via factory (CREATE2, atomic `initialize`) |
| Pools | arbitrary, one per `openPosition` | a fixed *set* configured at init (`PoolConfig[]`) |
| Capital | caller passes amounts + `liquidity` per call | deposit any stable → operator `allocate`s |
| Custody | full Envelop `SmartWallet` (ERC721/1155 holder, `executeEncodedTx`) | ERC20-only + one batch escape hatch (EIP-170) |
| Withdraw | `executeEncodedTx` → touches balances | **indirect** `withdrawTo` → PoolManager → recipient |
| Protocol fee | none | 10% on realized fees |

## Deployment & configuration

- **Factory clone.** `StableLPFactory.createManager(InitParams)` does `Clones.cloneDeterministic`
  (salt `keccak256(owner, nonce)`) then `initialize(p)` **atomically in the same tx** — no
  uninitialized-clone front-run window. The implementation constructor sets `_initialized = true`
  (locks the impl) and the immutables.
- **Immutables (shared across all clones, read through delegatecall):** `POOL_MANAGER` (per-chain V4
  singleton, in the base `V4PositionManager`), `PROTOCOL_TREASURY` (set by the protocol at impl deploy,
  **not** owner-settable). `PROTOCOL_FEE_BPS = 1000` is a `constant`.
- **`InitParams { address owner; bytes32 name; PoolConfig[] pools; }`** — `owner` receives the
  singleton NFT; `name` is the per-clone NFT name packed into `bytes32` (≤31 chars; empty ⇒ the default
  `"Envelop LP Uniswap Manager"`); the pool set is fixed at init (no `poolManager`/`quote` fields).
- **`PoolConfig { PoolKey key; int24 tickLower; int24 tickUpper; }`** — one config per pool.
- **Validation in `initialize`** (per pool): hookless-only (`key.hooks == address(0)` else
  `HookNotAllowed`); valid tick range; **duplicate-pool reject** (`DuplicatePool` — required because
  `salt == poolId`). Pool count bounded `1..MAX_POOLS` (`NoPools` / `TooManyPools`). `name()` is the
  per-clone `InitParams.name` (packed `bytes32`, trailing zeros trimmed), falling back to
  `"Envelop LP Uniswap Manager"` when empty; `symbol()` is the constant `"eStableLP"`.
- **`managedStables`** — the deduped union of every pool's `currency0`/`currency1`; this is the set of
  stables the manager recognizes (deposit + `withdrawTo` target + net-settlement set).

## Authorization

Auth root is the holder of the singleton NFT (`SingletonNFTOwned`, `TOKEN_ID = 1`). Two gates:

| Modifier | Who | Functions |
|---|---|---|
| `onlyOwnerNFT` | NFT holder only | `withdrawTo`, `executeEncodedTxBatch`, `setOperator`, `setPositionDescriptor` |
| `onlyAuthorized` | owner **or** operator | `allocate`, `allocateFrom`, `reinvest`, `claimFees` |

Operators are owner-delegated bots that can *manage positions* but **cannot move capital out** — the
drain primitive `withdrawTo` and the arbitrary-call hatch are owner-only. Operators are auto-cleared on
NFT transfer, and the active-operator list is kept compact (splice-on-disable) so a transfer can't be
gas-bricked.

## Position identity

`salt == poolId` — one position per configured pool. The registry maps `positions[salt]` and an
enumerable `openSalts`; a `mapping(PoolId => uint256) _poolIndexPlusOne` gives O(1) `poolId → config`
lookup **and** doubles as the init-time duplicate guard.

## Operations

All state-changing ops are `nonReentrant` and run inside a single `PoolManager.unlock`; the manager is
the sole `IUnlockCallback` (`msg.sender == POOL_MANAGER` enforced).

### `allocate(AllocLeg[] legs)` — auto
Deploy liquidity per `legs`, drawing from whatever managed-stable balances sit on the manager;
residuals net back. Operator-driven (off-chain sizing).

### `allocateFrom(Currency stable, uint256 amount, AllocLeg[] legs)` — manual
Deploy a specific just-deposited `stable` (`>= amount` must already sit on the manager →
`NotDeposited`). Snapshots all managed-stable balances pre/post and reverts `UnexpectedStableSpend` if
**any other** stable decreased — so a deposit-and-allocate can't dip into pre-existing holdings.

### `AllocLeg` (per pool action)
```solidity
struct AllocLeg {
    PoolId  poolId;          // which configured pool
    bool    zeroForOne;      // pre-swap direction (input side)
    uint256 swapAmountIn;    // exactIn pre-swap into the pool; 0 = none
    uint160 swapPriceLimit;  // sqrtPriceLimitX96 — slippage guard on the swap
    uint256 amount0Desired;  // operator-sized add amounts (these bound the spend per side)
    uint256 amount1Desired;
    uint128 minLiquidity;    // floor on minted L (slippage on the add)
}
```
The leg optionally pre-swaps (exactIn; `SwapSlippage` on a price-limited partial fill), then adds
liquidity sized via `liquidityFromAmounts(sqrtP, ticks, amount0Desired, amount1Desired)`. **Slippage
controls:** `minLiquidity` (L floor) + `swapPriceLimit` (per-swap price bound). There is **no
`amount*Max` cap** — it was removed as structurally redundant: because `L` is sized from `amountXDesired`
at the on-chain price and minted at that same price, realized owed is always `≤ amountXDesired` (Desired
already bounds the spend).

### `withdrawTo(WithdrawToParams p)` — indirect drain (owner-only)
```solidity
struct WithdrawToParams {
    address recipient;
    Currency requestedStable;     // must be managed
    uint256 amount;               // exact amount delivered to recipient
    WithdrawStep[] pulls;         // {PoolId poolId; uint128 liquidityToPull}
    WithdrawSwap[] swaps;         // {PoolId poolId; bool zeroForOne; int256 amountSpecified; uint160 limit}
    bool reinvestRemainder;       // no-op (phase-1; residuals always return to the manager)
}
```
Inside one unlock: pull liquidity from `pulls` (principal + fees become positive deltas; protocol fee
skimmed from the fee component), convert freed legs via `swaps`, require
`currencyDelta(requestedStable) >= amount` (`AmountNotDelivered`), `take(requestedStable, recipient,
amount)` **straight from PoolManager to the recipient**, then `_settleManaged` returns residuals to the
manager. The requested stable never touches the manager/owner balance. `reinvestRemainder` is accepted
for ABI/spec compat but ignored.

### `reinvest(AllocLeg leg)` — compound (operator/owner)
Realize fees (`modifyLiquidity(0)`), skim the protocol cut, optionally pre-swap, then **add the
remaining 90% back into the position** sized from the realized deltas.

### `claimFees(bytes32 salt)` — harvest (operator/owner)
Poke (`modifyLiquidity(0)`) to realize fees; skim the protocol cut; the remaining 90% lands on the
manager's balance.

### `executeEncodedTxBatch(targets, values, datas)` — owner escape hatch
Arbitrary owner-only calls (rescue tokens, claim airdrops, approve a spender, native sends). Operators
cannot use it.

## Protocol fee (10%)

A constant `PROTOCOL_FEE_BPS = 1000` (10%) of **every realized fee accrual** is skimmed to
`PROTOCOL_TREASURY`. Implementation: each `modifyLiquidity` returns `feesAccrued` as its second value;
`_skimFees` takes `ceil(feesAccrued * 10%)` per currency (round-up favors the protocol; sub-threshold
amounts round to 0). The skim happens at **every** fee-realizing site, so it is **unavoidable**:

- `allocate` top-up of an existing position (`_addLiquidity`), `reinvest` realize, `withdrawTo` pull,
  `claimFees` poke. A fresh position (first add) has `feesAccrued == 0` → no skim; **principal is never
  taxed**.

**ERC-6909, not ERC-20.** The skim uses `take(..., claims=true)` → `mint(treasury, currencyId, cut)`,
crediting the treasury an **ERC-6909 claim inside PoolManager** rather than an ERC-20 transfer. This is
deliberate: a stablecoin **blocklist/pause on the treasury cannot revert the unlock** and lock LP
principal (the withdraw path is the only exit). The treasury redeems later via
`unlock → burn(claims) → take` (so the treasury should be, or delegate to, a contract able to run that
flow — a plain EOA holds the claims but needs a redeemer).

**Where the residual 90% goes** (see flow diagrams): on `allocate` top-up / `claimFees` it nets to the
manager's **balance** (reduced settlement / taken to self) — *not* auto-compounded; on `reinvest` it is
explicitly **compounded** back into the position.

## Native ETH

A configured pool may be `ETH/token`: native is `Currency(address(0))`, always `currency0`.
`CurrencySettler` routes the native side via `settle{value:}` (paid from the manager's ETH balance) and
`take` (ETH sent out); the manager custodies ETH via `receive()`. `managedStables`/`balanceOfSelf`/the
`allocateFrom` snapshot all work with `Currency(0)`. (Covered by `test/StableLPManagerNative.t.sol`.)

## Metadata

`tokenURI(1)` delegates to an external `IWalletDescriptor` (owner-set via `setPositionDescriptor`; zero
⇒ `""`, never reverts) — rendering bytecode lives outside the clone (EIP-170). Every position mutation
emits ERC-4906 `MetadataUpdate(TOKEN_ID)`; `setPositionDescriptor` too.

## Risks & assumptions

From the multi-agent audit (`AUDIT-REPORT.md`). No external fund-drain found. Status: **FIXED** in code
or **DOCUMENTED/ACCEPTED**.

| Sev | Risk | Status |
|----|------|--------|
| HIGH | Protocol-fee skim to an immutable treasury via ERC-20 → a stablecoin blocklist/pause on the treasury would revert the only exit path and **lock LP principal**. | **FIXED** — skim as ERC-6909 claims (`_takeClaim`). |
| MEDIUM | `withdrawTo` swaps / `allocate` `getSlot0` sizing have **no TWAP/oracle**; slippage protection is entirely operator-supplied (`minLiquidity`, `swapPriceLimit`). A loose param + a sandwich extracts value (owner/operator-gated, not external). | DOCUMENTED — relies on stable pools being deep/pegged + operator discipline (tight `swapPriceLimit`). |
| LOW | Operator-list could be grown to gas-brick NFT transfer. | **FIXED** — splice-on-disable. |
| LOW | Protocol fee rounded down (sub-threshold zero-skim). | **FIXED** — round up. |
| LOW | `_addLiquidity` missing uninitialized-pool guard. | **FIXED** — `PoolUninitialized`. |
| LOW | auto-`allocate` has no aggregate cap — an operator can deploy the manager's **entire idle balance** (recoverable; not theft). | DOCUMENTED — operator-trusted by design. |
| LOW/INFO | **Fee-on-transfer / rebasing** tokens break `_settle` / the `allocateFrom` snapshot / `withdrawTo` delivery (all assume `received == sent`). | DOCUMENTED — managed currencies must be standard ERC-20 (or native). |
| INFO | Protocol fee accrues as **ERC-6909**; the treasury must redeem via `unlock→burn→take`. | Resolved — use `src/FeeRedeemer.sol` as the treasury (task_018). |
| INFO | No deadlines on entry points; no two-step NFT ownership handoff; `reinvestRemainder` is a no-op. | ACCEPTED. |
| — | Pools are **hookless-only** (categorical reject); positions are operator-driven so all slippage discipline lives off-chain. | By design. |

## EIP-170

`StableLPManager` is a clone, so its runtime must stay under 24,576 B. Current margin ≈ **604 B**
(after dropping `SmartWallet` inheritance, the `amount*Max` caps, and the `ownerNFTHolder` alias). Next
sizeable feature likely needs a lever (lower `optimizer_runs`, immutable→storage, or extract
allocate/withdraw into a delegatecall library).

## Tests

`test/StableLPManager*.t.sol` (allocate/allocateFrom + guard, withdrawTo, reinvest/claimFees, factory +
dup/bounds, managed-stable union, 7-pool config), `StableLPManagerProtocolFee.t.sol` (exact 90/10 split,
ERC-6909 skim, zero-treasury revert), `StableLPManagerAuditFixes.t.sol`, `StableLPManagerNative.t.sol`
(ETH pair). Run: `forge test --match-path "test/StableLP*.t.sol" -vvv`.

## Changelog / refs

Task history: `task_010` (initial), `task_011` (EIP-170 shrink), `task_012` (hookless-only),
`task_014` (v2: arbitrary pools, multi-stable, poolId-keying, immutable PoolManager), `task_015`
(protocol fee + ERC-6909 fix), `task_016` (audit remediation). Asset/delta diagrams:
`StableLPManager_flows_ru.md`. Audit: `AUDIT-REPORT.md`.
