# Task 014 — StableLPManager v2: arbitrary stable pools + multi-stable allocate

## Goal

Generalize `StableLPManager` from its narrow v1 model (one common `QUOTE` stable, exactly 3 fixed
pools, weight-based split of a single deposit) to:

- **Arbitrary stable pools** (a mesh of pairs — no common hub/quote required). The `QUOTE` concept is
  removed entirely; "managed stables" = the union of all pool currencies.
- **Any managed stable can be deposited**, not just one quote.
- **Two allocate modes** (operator drives the split off-chain in both):
  - `allocate(AllocLeg[] legs)` — *auto*: deploy from whatever managed-stable balances sit on the
    manager; residuals net back.
  - `allocateFrom(Currency stable, uint256 amount, AllocLeg[] legs)` — *manual*: deploy a specific
    just-deposited `stable`, **guarded so only that stable may be drawn down** (every other managed
    stable must end ≥ its pre-call balance — a deposit-and-allocate can't dip into prior holdings).
- **Variable pool count** — dynamic `PoolConfig[]`, capped at `MAX_POOLS = 8`.

Also removes fields that were already dead in v1 (never read by logic): `PoolConfig.quoteSide`,
`PoolConfig.weightBps` (+ `TOTAL_BPS`/`WeightsNotFull`).

## Changes — `src/StableLPManager.sol`

- **Removed:** `QUOTE` state, `InitParams.quote`, `PoolConfig.quoteSide`, `PoolConfig.weightBps`,
  `_isQuoteCurrency0`, `_pairSide`, quote-centric leg fields (`quoteIn`/`swapQuoteToPair`/`totalQuote`)
  and `AllocateParams`, errors `WeightsNotFull`/`QuoteSplitMismatch`.
- **Pools dynamic:** `PoolConfig[3]` → `PoolConfig[]`; `initialize` validates `1 ≤ len ≤ MAX_POOLS`
  (`NoPools`/`TooManyPools`) and builds an enumerable `Currency[] managedStables` (deduped union via
  `_registerManaged`). New views `poolCount()` / `managedStablesCount()`.
- **New `AllocLeg`** (quote-agnostic, self-describing): `poolIndex, zeroForOne, swapAmountIn,
  swapPriceLimit, amount0Desired, amount1Desired, minLiquidity, amount0Max, amount1Max`. `_allocateLeg`
  does an optional exactIn pre-swap (with partial-fill `SwapSlippage` guard) then reuses `_addLiquidity`.
- **`allocate` / `allocateFrom`** as above; `allocateFrom` snapshots all managed-stable balances and
  reverts `UnexpectedStableSpend(c)` if any non-named stable decreased (`NotDeposited` if the named
  stable isn't present).
- **`_settleManaged`** now iterates `managedStables` (was hardcoded QUOTE + 3 pair sides). `reinvest`
  takes its swap direction from `leg.zeroForOne`. Pool-index bounds checks use `pools.length`.

`StableLPFactory` is unchanged (InitParams now carries a dynamic `pools` array).

## Tests

- Updated `StableLPTestBase` helpers (`_initParams` dynamic pools, `_allocateParams` → `AllocLeg[]`),
  and the Allocate/Withdraw/Reinvest/Factory suites to the new API.
- New `test/StableLPManagerV2.t.sol`: managed-stable union count; `allocateFrom` manual happy-path
  (only named stable consumed); manual **guard** revert (`UnexpectedStableSpend`); `NotDeposited` /
  `UnmanagedStable`; a standalone **7-pool** manager (`poolCount`/`managedStablesCount`).
- Replaced the removed `quoteSplitMismatch`/`weightsNotFull` tests with `noLegs`/`unknownPool` /
  `noPools`/`tooManyPools`.

## Result / EIP-170

`StableLPManager` runtime ~23,995 bytes — under the 24,576 limit (margin ~581), so no library split was
needed (the deferred decision resolved in favor of keeping a single contract). All tests green:
110 pass, 1 fork test skipped without `BASE_RPC`.

## Verification

```bash
forge fmt --check
forge build --sizes        # StableLPManager under EIP-170
forge test --match-path "test/StableLP*.t.sol" -vvv
forge test                 # full regression (110 pass / 1 skipped)
```

## Review follow-up — poolId-keyed config

Review feedback removed two redundant identifiers (one pool = one position):

- **Dropped `PoolConfig.baseSalt`.** Position salt is now the **poolId** itself
  (`salt = PoolId.unwrap(key.toId())`) — predictable off-chain, no operator-chosen seed.
- **`AllocLeg.poolIndex` / `WithdrawStep.poolIndex` / `WithdrawSwap.poolIndex` → `PoolId poolId`.**
  Legs/steps reference the pool self-descriptively; resolved via a new
  `mapping(PoolId => uint256) _poolIndexPlusOne` (`_indexOf` reverts `UnknownPool(id)`).
- **`initialize` rejects duplicate pools** (`DuplicatePool(id)`) — required since poolId is now the
  salt/registry key.
- `reinvest(uint8, AllocLeg)` → `reinvest(AllocLeg)` (pool taken from `leg.poolId`). `_addLiquidity`
  takes `(PoolId, PoolConfig, …)`. Errors `UnknownPool`/`SwapSlippage` now carry `PoolId`. New
  `test_initialize_duplicatePool_reverts`; suites updated to pass poolIds.

Net effect on size: **smaller** — `StableLPManager` ~23,397 bytes (margin ~1,179), the salt
simplification outweighed the lookup mapping. 111 tests pass, 1 fork test skipped without `BASE_RPC`.

### `POOL_MANAGER` as a shared immutable

The V4 PoolManager is a per-chain singleton, so it doesn't need to be per-clone config:

- Replaced storage `IPoolManager _pm` (set in `initialize`) with `IPoolManager public immutable
  POOL_MANAGER`, set in the implementation **constructor** (`constructor(IPoolManager)`). Clones read
  it through delegatecall (immutables live in code, shared by all clones).
- Dropped `InitParams.poolManager` — the factory clones an implementation already wired to the chain's
  PoolManager. Factory code unchanged. `Initialized` event emits `address(POOL_MANAGER)`.

Trade-off (corrected): this **does not shrink** the contract. `POOL_MANAGER` is read at ~13 call
sites and an immutable inlines its value at each site, which costs *more* bytecode than a storage slot
+ SLOADs — runtime grew to ~23,849 bytes (margin ~727, still under EIP-170). The win is **runtime gas**
(no SLOAD per read), a smaller `InitParams`, and matching the per-chain-singleton reality / the
`UniSmartWallet` immutable pattern. Tests deploy the impl with the PoolManager
(`new StableLPManager(IPoolManager(address(poolManager)))`). 111 tests pass, 1 fork skipped.
