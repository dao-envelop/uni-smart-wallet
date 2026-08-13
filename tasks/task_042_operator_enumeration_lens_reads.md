# task_042 — On-chain operator enumeration + close the remaining `UniLens` read gaps

Make the manager's **active operator set** readable on-chain, and fold the two other reads that still
force off-chain workarounds (`StableLPManager` position bounds, the operator-swap oracle guard) into
`src/UniLens.sol`.

> **Scope of this task = contracts + tests.** Redeploying `UniLens` per chain and wiring `stablelp-ui`
> (`src/lib/data/operators.ts`, `mcp/reads.ts`) onto the new reads is a **separate follow-up**, because
> the fallbacks below must stay for already-deployed managers.

## Why

Three reads currently have no on-chain path, and each one is worked around differently off-chain:

1. **Operator set.** `SingletonNFTOwned` keeps `address[] internal _operatorList` but exposes only the
   point-check `operators(address) → bool`. To list operators, `stablelp-ui/src/lib/data/operators.ts`
   (`fetchOperators`, reused by `mcp/reads.ts:113` and the `list_operators` MCP tool) folds the entire
   `OperatorSet` log history from the factory deploy block, chunking by 10k blocks when the RPC refuses
   the range. Slow, provider-dependent, and it degrades as history grows.
2. **Stable position bounds.** A pool has no range — a range belongs to a position. What the stable
   product fixes at `initialize` is policy: one position per pool, always between the same ticks. Those
   bounds lived in `StableLPManager._range`, which is `internal`, and **nothing emits them** —
   `Initialized` carries only owner/poolManager/poolCount. Before the first `allocate` there is no
   position to read ticks off, so they were recoverable only by decoding the factory's creation calldata.
3. **Operator-swap guard.** Predicting whether an operator swap will pass needs a 4-deep *dependent*
   read chain: `priceOracle` → `maxDeviationBps` / `sequencerUptimeFeed` / `sequencerGracePeriod` →
   `feeds(currency)` per managed currency. A missing feed is exactly what makes an operator swap revert
   `OperatorSwapUnverified`, and today that is only discoverable by burning the gas.

## The EIP-170 constraint (this drove the design)

`StableLPManager` is the tightest contract in the repo. Measured on `master` (3515291) with the repo's
own profile (`solc 0.8.26`, `optimizer_runs = 200`, `via_ir = false`):

| variant | StableLPManager | Δ | headroom |
|---|---|---|---|
| baseline | 23,911 | — | 665 |
| `operatorCount()` only | 23,942 | +31 | 634 |
| **`address[] public operatorList` + `operatorCount()`** | **23,999** | **+88** | **577** |
| `operatorList() → address[] memory` | 24,126 | +215 | 450 |

Returning the array from the manager costs **215 B — a third of the entire remaining budget**. The
index getter costs 88 B and `UniLens` (10 KB+ free, standalone, not clone-deployed) does the array build
instead. This mirrors the existing `openSalts` / `openPositionCount` ↔ `UniLens.positions` split, so it
is the codebase's own pattern rather than a new one.

Adding `rangeOf` costs a further **+95 B** (final: 24,094 / **482 B headroom**). `VolatileLPManager`
ends at 23,718 (858 B headroom). Everything else lands in the lens at zero manager cost.

**Runtime gas is not affected**: all additions are `view`, and the storage layout is unchanged (the
`_operatorList` → `operatorList` rename is a visibility change only), so `setOperator` /
`_clearOperators` cost exactly what they did.

## Contract changes

### `src/abstract/SingletonNFTOwned.sol`

- `address[] internal _operatorList` → `address[] public operatorList` (all in-file references renamed).
- New `operatorCount() → uint256`.
- Order is **not** stable: disable does swap-and-pop. Documented on the variable; consumers must treat
  the enumeration as a set.

### `src/StableLPManager.sol`

- `mapping(PoolId => Range) internal _range` → `public rangeOf` (auto-getter returns `(int24,int24)`).

### `src/UniLens.sol`

- `operators(address manager) → address[]` — aggregates `operatorCount()` + `operatorList(i)`.
- `stableRanges(address manager) → StableRange[]` — `{poolId, tickLower, tickUpper}` per configured pool,
  index-aligned to `managerConfig(...).pools`. **`StableLPManager`-only** (volatile ranges are per-call),
  so it reverts on a volatile manager by design.
- `oracleStatus(address manager) → OracleStatus` — `{oracle, isChainlinkLike, maxDeviationBps,
  sequencerUptimeFeed, sequencerGracePeriod, feeds[]}` with one `OracleFeedInfo`
  `{currency, aggregator, heartbeat, feedDecimals, tokenDecimals}` per managed currency, index-aligned to
  `ManagerConfig.managed`. `aggregator == address(0)` is the "this currency will revert an operator swap"
  signal.
  - Defensive by construction: `priceOracle` is only an `IPriceOracle`. A non-Chainlink implementation
    yields `isChainlinkLike == false` with the rest zeroed (`try/catch`), and a **non-contract** oracle is
    short-circuited on `code.length == 0` *before* the typed calls — `setPriceOracle` does not require a
    contract, and the compiler's `extcodesize` check is not catchable by `try/catch`.
  - The probe interface `IChainlinkOracleView` is declared locally in `UniLens.sol` rather than importing
    the concrete oracle, so the lens stays implementation-agnostic.

**No existing ABI changed.** `PoolInfo` / `ManagerConfig` / `ManagerView` / `PositionView` are untouched,
so the redeploy is additive for current consumers.

## Tests — `test/UniLensOperatorsOracle.t.sol` (new, 13 tests)

Operator enumeration: empty at init; parity with the `operators` mapping + no duplicates; splice-on-disable
drops only that operator; 50 enable/disable cycles stay compact (the churn bug the splice fixed would show
up here as stale entries); auto-clear on NFT transfer; out-of-range index reverts.
Ranges: match the `initialize` params and `rangeOf`, and are readable with **zero positions open**.
Oracle status: no oracle; a real `ChainlinkPriceOracle` with a feed on exactly one managed currency (the
others must surface `aggregator == 0`); sequencer feed/grace surfaced; a non-Chainlink `IPriceOracle`
degrades instead of reverting; an EOA oracle degrades instead of reverting.

Existing `test/StableLPManagerAuditFixes.t.sol` operator tests keep passing unchanged.

## Verification

```bash
forge build --sizes   # StableLPManager 24,094 (<24,576); VolatileLPManager 23,718; UniLens 14,532
forge test            # 211 passed, 0 failed, 3 skipped (fork tests, env-gated by BASE_RPC)
forge fmt --check
```

## Follow-ups (not this task)

1. **Redeploy `UniLens`** on all 5 chains (1, 130, 1301, 8453, 42161) and update the addresses baked into
   `stablelp-ui`, as in task_040.
2. **Wire `stablelp-ui` + `mcp/`**: prefer `lens.operators` / `lens.oracleStatus`, and **keep**
   `fetchOperators` (log folding) and the two-step oracle read as fallbacks — **managers deployed before
   this task are clones of the old implementation and will never have these getters.** The fallback is
   permanent for them, not transitional.
3. Fix `CLAUDE.md`, which claims `optimizer_runs = 800` while `foundry.toml` says 200.
