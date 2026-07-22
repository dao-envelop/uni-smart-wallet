# task_040 — UniLens read aggregator (fewer frontend round-trips) + redeploy

Extend `src/UniLens.sol` with richer, single-call read aggregators so the `stablelp-ui` manager screens
stop fanning out ~9 RPC round-trips per page, and redeploy the lens to every chain (the deployed one is
stale on all of them).

> **Scope of this task = the contract + its tests + deploy.** Frontend wiring (new hooks, fallback
> chain, folding the scattered reads) is a **separate follow-up** in `stablelp-ui`, done after this
> deploys. Full cross-repo plan: `~/.claude/plans/wiggly-honking-patterson.md`.

## Why

On-chain audit (2026-07-22): **all 5 deployed lenses are the same stale build — 7483 B** (mainnet 1,
unichain 130, unichain-sepolia 1301, base 8453, arbitrum 42161), while current `src/UniLens.sol` compiles
to **6992 B** and has never been deployed. The stale `managerInfo` **reverts on volatile managers**
(verified on arbitrum manager `0x60723973ABF3BBC2ce7EB4400B728390D55e264b`; identical bytecode ⇒ same bug
everywhere). `positions()` works. The frontend already worked around this by reading the manager directly
in 3 sequential multicall phases (`stablelp-ui` `useManagerInfo`) + scattered reads of `ORACLE_TYPE`,
`positionDescriptor`/`tokenURI`, `priceOracle`, per-stable `symbol`/`decimals`, an unmanaged-idle probe,
and per-pool `getSlot0`/`getLiquidity`. All of that is aggregatable on-chain.

Decision (user): ship **both** a rich config getter and a max "everything" getter so the frontend can A/B
which performs better; keep `managerInfo`/`positions`/`position` for backwards-compat (do not change their
ABIs).

## Contract changes — `src/UniLens.sol`

UniLens is standalone (not clone-deployed) ⇒ the 24 KB limit is not tight; add generously.

New types:

```solidity
struct StableInfo { Currency currency; uint8 decimals; string symbol; uint256 idle; } // address(0)=native
struct PoolInfo   { PoolKey key; uint160 sqrtPriceX96; uint128 liquidity; }            // live price per configured pool
struct ManagerConfig {
    address owner; uint16 protocolFeeBps; address treasury;
    uint256 oracleType;                 // product tag: 3000 stable / 3001 volatile
    address positionDescriptor; address priceOracle; string name;
    StableInfo[] managed;               // managed stables + decimals/symbol/idle (index-aligned to managedStables)
    StableInfo[] extra;                 // caller-supplied extraTokens with a NON-ZERO idle and not already managed
    PoolInfo[]  pools;                  // configured pools + live slot0/liquidity
}
struct ManagerFull { ManagerConfig config; PositionView[] positions; }
```

New external views:

```solidity
function managerConfig(address manager, address[] calldata extraTokens) external view returns (ManagerConfig memory);
function managerFull  (address manager, address[] calldata extraTokens) external view returns (ManagerFull  memory);
```

Implementation notes:
- Reuse the `managerInfo` loop (owner/fee/treasury/managed/idle/pools) and the `positions()` loop (for
  `ManagerFull.positions`). Product-agnostic, stateless — same conventions as existing getters.
- `oracleType = BaseLPManager(m).ORACLE_TYPE()`; `positionDescriptor = m.positionDescriptor()`;
  `priceOracle = m.priceOracle()`; `name = m.name()` — all existing public getters.
- **Safe token metadata helper**: read `decimals`/`symbol` via low-level `staticcall` + try-decode
  `string`, falling back to `bytes32` symbol and to empty on revert. Native (`address(0)`) ⇒ decimals 18,
  symbol `"ETH"`. Do NOT use a bare `IERC20Metadata` cast (some tokens revert or return `bytes32`).
- `extra[]`: for each `extraTokens[i]` not in `managedStables` with `balanceOf(manager) > 0`, include it
  (frontend passes the chain's stablecoin list to surface stray/unmanaged idle, e.g. USDT on a USDC/ETH
  manager).
- `PoolInfo`: `pm = m.POOL_MANAGER()`; `StateLibrary.getSlot0(pm, poolId)` → `sqrtPriceX96`,
  `getLiquidity(pm, poolId)` → `liquidity`. `StateLibrary` is already imported (`UniLens.sol:7`).
- **Do NOT include `tokenURI`** (heavy base64 SVG would bloat every response) — the frontend keeps a
  separate cache-forever `tokenURI` read; `positionDescriptor` in the config already signals whether one is
  wired.
- Out of scope (later): oracle config (`maxDeviationBps`/`sequencerUptimeFeed`/`sequencerGracePeriod`) — a
  separate `oracleConfig(address)` view can be added when the oracle screen is optimized.

## Tests — `test/UniLens.t.sol`

Mirror the existing `test_managerInfo` / `test_positions` conventions:
- `managerConfig`: managed/idle/decimals index-aligned; `oracleType`, `positionDescriptor`, `priceOracle`,
  `name` populated; `extra` contains only non-zero, not-already-managed tokens (feed a mock stable with a
  balance and one with zero → only the funded one appears); `pools[i].sqrtPriceX96 == StateLibrary.getSlot0`
  and `liquidity == getLiquidity`.
- `managerFull.config` equals `managerConfig` and `.positions` equals `positions()`.
- Cover a native-ETH managed currency (decimals 18, symbol "ETH", native balance).
Run `forge fmt`, `forge test -vvv`, `forge build --sizes` (UniLens < 24 KB).

## Deploy

`script/DeployStableLP.s.sol` already deploys `new UniLens()` under the `lens` flag from
`chain_params.json` (~L182/273) and writes the address into `deployments/<chainId>.json` (~L350/366). Set
**only** the `lens` flag and run on all 5 chains (1 / 130 / 1301 / 8453 / 42161). Deployer keys + gas are an
operational step.

## Verification

- `forge test`, `forge build --sizes`.
- After deploy — live probe (node + viem) against arbitrum `0x60723973ABF3BBC2ce7EB4400B728390D55e264b`:
  `managerFull`/`managerConfig` ⇒ `pools.length == 4`, managed `[ETH, USDC, WBTC]`,
  `extra == [USDT 25_000000]`, `oracleType == 3001`, `positionDescriptor`/`priceOracle` set,
  `pools[i].sqrtPriceX96 != 0`.
- Do NOT rename/drop `EnvelopV2OracleType` / `EnvelopWrappedV2` events; keep `managerInfo`/`positions`/
  `position` unchanged for backwards-compat.

## Follow-up (separate session, `stablelp-ui`)

Sync ABI + new lens addresses (`scripts/sync-abi.mjs`, `scripts/sync-deployments.mjs`), add
`useManagerFull` (primary) → `managerConfig` → existing direct-read `useManagerInfo` fallback chain (keep
direct reads for resilience to a future stale lens), and fold `useProduct` / descriptor read /
`useTokenMetas` (managed) / idle-extra probe / `usePoolsLiquidity` into the aggregate. See the plan file.
