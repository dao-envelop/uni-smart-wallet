# ChainlinkPriceOracle `maxDeviationBps` — Chainlink vs Uniswap V4 basis

Snapshot to size `ChainlinkPriceOracle.maxDeviationBps` for deploy. Produced by
`script/PriceDeviation.s.sol` against **live** state (one block, ~2026-07-20) on the 5 chains that have a
deployed stack. All PoolKeys were verified on-chain via the V4 `PoolManager.Initialize` event (poolId
cross-checked as `keccak256(abi.encode(PoolKey))`). Chainlink prices come from the feeds in
`script/oracle_feeds.json`.

## Method

The oracle guards an operator swap by requiring `realizedOut >= expectedOut * (1 - maxDeviationBps)`,
where `expectedOut` is from the two USD feeds and `realizedOut` is what the pool gives (net of fee +
slippage). So `maxDeviationBps` must cover:

```
basis (|V4 mid − Chainlink cross| / Chainlink)  +  pool fee  +  execution slippage/buffer
```

The script measures **basis** per pool from live `getSlot0`, then reports `min maxDeviationBps = basis +
poolFee + BUFFER(50 bps)`. Reproduce:

```bash
POOLS_CONFIG=script/price_pools/<chainId>.json \
  forge script script/PriceDeviation.s.sol --sig "run()" --rpc-url $RPC
```

## Results (single snapshot, 2026-07-20; ETH ≈ $1.86–1.88k, BTC ≈ $64.6k)

### Ethereum mainnet (1) — worst suggestion **96**
| Pool | Fee | Basis (bps) | Fee (bps) | min maxDeviationBps |
|---|---|---|---|---|
| ETH/USDC | 0.05% | 20 | 5 | 75 |
| ETH/USDC | 0.30% | 16 | 30 | **96** |
| ETH/USDT | 0.05% | 24 | 5 | 79 |
| USDC/USDT | 0.0007% | 3 | 0 | 53 |
| USDC/cbBTC | 0.30% | 3 | 30 | 83 |
| ETH/WBTC | 0.05% | 33 | 5 | 88 |
| WBTC/USDC | 0.05% | 17 | 5 | 72 |

### Base (8453) — worst suggestion **92**
| Pool | Fee | Basis (bps) | Fee (bps) | min maxDeviationBps |
|---|---|---|---|---|
| USDC/cbBTC | 0.05% | 10 | 5 | 65 |
| ETH/USDC | 0.30% | 6 | 30 | 86 |
| USDC/USDT | 0.0007% | 3 | 0 | 53 |
| ETH/cbBTC | 0.05% | 11 | 5 | 66 |
| ETH/USDC | 0.05% | 1 | 5 | 56 |
| ETH/cbBTC | 0.30% | 12 | 30 | **92** |

### Arbitrum One (42161) — worst suggestion **98**
| Pool | Fee | Basis (bps) | Fee (bps) | min maxDeviationBps |
|---|---|---|---|---|
| ETH/USDC | 0.30% | 18 | 30 | **98** |
| ETH/USDC | 0.05% | 3 | 5 | 58 |
| ETH/USDT | 0.05% | 0 | 5 | 55 |
| USDC/USDT | 0.0008% | 0 | 0 | 50 |
| USDC/DAI | 0.01% | 0 | 1 | 51 |
| WBTC/USDC | 0.05% | 14 | 5 | 69 |
| ARB/USDC | 0.30% | 2 | 30 | 82 *(thin pool ~$32k, noisy)* |

### Unichain (130) — worst suggestion **91**
*(Chainlink feeds here are 18-decimal SVR proxies; no L2 Sequencer Uptime Feed exists.)*
| Pool | Fee | Basis (bps) | Fee (bps) | min maxDeviationBps |
|---|---|---|---|---|
| ETH/USDC | 0.05% | 11 | 5 | 66 |
| ETH/WBTC | 0.05% | 3 | 5 | 58 |
| ETH/UNI | 0.30% | 11 | 30 | **91** |

### Unichain Sepolia (1301) — not measurable
No usable V4 pools: the PoolManager is active but every pool pairs arbitrary mock ERC-20s (no native-ETH
pool, no canonical/Circle USDC pool). Testnet prices are not meaningful for tuning — set its
`maxDeviationBps` to match Unichain mainnet (or a conservative default) at deploy.

## Snapshot 2 (2026-07-21) — worst `min maxDeviationBps` per chain

| Chain | Snapshot 1 (07-20) | Snapshot 2 (07-21) | Note |
|---|---|---|---|
| Ethereum (1) | 96 | 95 | stable |
| Base (8453) | 92 | 88 | ↓ |
| Arbitrum (42161) | 98 | 106 | ↑ — driven by thin ARB/USDC 0.30% (basis 26 bps, noisy ~$32k pool) |
| Unichain (130) | 91 | **152** | ↑↑ — see finding below |

Per-pool basis (bps) day-1 → day-2 for the movers: Ethereum WBTC/USDC 17→21; Arbitrum WBTC/USDC
14→17, ARB/USDC 2→26; **Unichain ETH/WBTC 3→39, ETH/UNI 11→72** (ETH/USDC stayed 11→6).

### Finding — Unichain basis is dominated by SVR feed lag, not pool mispricing
Unichain Chainlink feeds are **18-decimal SVR proxies with a 24h heartbeat** — they update infrequently
(daily / on large deviation). The V4 pool tracks price in real time, so for volatile assets (BTC, UNI)
the *feed* lags the pool and the measured "basis" is mostly **feed staleness**, not a real gap. ETH stays
tight because ETH moved less / its feed is fresher. Consequence: a tolerance wide enough to accommodate
the stale-feed basis (150+ bps) would be too loose to catch manipulation. Combined with Unichain having
**no** L2 Sequencer Uptime Feed, the guard is weak there for BTC/UNI. Practical: on Unichain, gate
operators only on stable/ETH pairs, or don't rely on this oracle for BTC/UNI.

> Two snapshots is still a small sample. Keep running (`memory: oracle-maxdev-price-deviation-tool`) to
> build a real distribution before committing to a number.
>
> **Superseded by Series 3 below** (2026-09-07): sampled rather than snapshotted, and the conclusion in
> this section — that a tolerance wide enough for the SVR lag would be too loose to catch manipulation —
> no longer holds, because task_054 moved the attack bound onto a separate parameter.

## Series 3 (2026-09-07) — 7 samples per pool over 25 minutes

First run that is a **sample rather than a snapshot**: `PriceDeviation.s.sol` on all four chains, seven
rounds ~3.5 min apart, public RPCs. Basis in bps.

### Ethereum (1)
| Pool | n | min | med | max |
|---|---|---|---|---|
| USDC/BTC 0.30% | 7 | 25 | 25 | **25** |
| ETH/USDC | 14 | 5 | 15 | 19 |
| ETH/USDT 0.05% | 7 | 5 | 15 | 16 |
| ETH/BTC 0.05% | 7 | 9 | 10 | 10 |
| BTC/USDC 0.05% | 7 | 0 | 1 | 2 |
| USDC/USDT `fee 7` | 7 | 1 | 1 | 1 |

### Unichain (130)
| Pool | n | min | med | max |
|---|---|---|---|---|
| ETH/UNI 0.30% | 7 | 84 | 91 | **123** |
| ETH/BTC 0.05% | 7 | 25 | 27 | 27 |
| ETH/USDC 0.05% | 7 | 1 | 6 | 16 |

### Base (8453)
| Pool | n | min | med | max |
|---|---|---|---|---|
| ETH/cbBTC | 14 | 2 | 13 | **32** |
| ETH/USDC | 14 | 3 | 6 | 13 |
| USDC/cbBTC 0.05% | 7 | 0 | 6 | 6 |
| USDC/USDT `fee 7` | 7 | 0 | 0 | 0 |

### Arbitrum (42161)
| Pool | n | min | med | max |
|---|---|---|---|---|
| ARB/USDC 0.30% | 7 | 4 | 13 | **30** |
| ETH/USDC | 14 | 0 | 3 | 11 |
| BTC/USDC 0.05% | 7 | 7 | 8 | 10 |
| ETH/USDT 0.05% | 7 | 0 | 1 | 6 |
| USDC/USDT, USDC/DAI | 7 | 0 | 0 | 0 |

**The spread inside 25 minutes settles the "one snapshot is not enough" argument.** Unichain ETH/UNI
moved 84 → 123 and Base ETH/cbBTC 2 → 32 within the window; a single reading would have understated
either by 3–15×. Stable pairs are 0–1 bps everywhere and never move.

### What this sizes, after task_054

The second iteration of task_054 **split the roles apart**, and that is what makes this number choosable:

| Tolerance | Bounds | Sized from |
|---|---|---|
| `maxDeviationBps` | an operator swap's realized price | basis + pool fee + execution buffer |
| `maxSpotDeviationBps` (`d`) | pool vs reference on an operator **add** | **availability only** — must cover the basis, `basis_p99 < d` |
| `maxMidOffsetBps` (θ) | the position midpoint vs reference | the accepted residual: `take ≈ θ − poolFee` per operation |

**`d` is no longer a security parameter.** Whatever the pool price does, an operator position must be
centred within θ of the *reference*, so the manager's liquidity sits at the fair price and a sweep
through it yields `θ − fee` regardless of how far the pool wandered. A skewed operator *swap* is refused
separately, by `maxDeviationBps`. So `d` may be set generously to keep honest operations alive.

**This retires the July conclusion.** Snapshot 2 concluded that "a tolerance wide enough to accommodate
the stale-feed basis (150+ bps) would be too loose to catch manipulation", and that on Unichain one
should "gate operators only on stable/ETH pairs, or not rely on this oracle for BTC/UNI". That was
correct when `d` was the only bound. It is not the trade-off any more.

### Values set (2026-09-07, `script/chain_params.json`)

| Chain | worst observed | `oracleMaxSpotDeviationBps` | note |
|---|---|---|---|
| Ethereum (1) | 25 | **40** | worst × 1.5 |
| Unichain (130) | 123 | **185** | driven by 18-decimal SVR proxies on a 24 h heartbeat, not pool mispricing |
| Base (8453) | 32 | **50** | |
| Arbitrum (42161) | 30 | **45** | |
| Unichain Sepolia (1301) | — | 50 | no measurable pools; default |

`oracleMaxMidOffsetBps = 10` on every chain — a product decision, not a measurement: it is the residual
accepted per operation (≈9 bps on a 0.01% pool) and equally the room an honest operator has for a
deliberately asymmetric range.

**The narrow alternative for Unichain**, if 185 bps of pool-vs-feed slack is judged too permissive as a
sanity check: keep ETH/UNI out of operator-managed sets and set `d = 40` (covers ETH/BTC at 27 × 1.5).
That is an owner decision about which pools a bot manages, and it no longer affects the attack bound.

**Still open:** this sample is intra-day and calm. Re-run through a volatile window before treating the
numbers as final; `PriceDeviation.s.sol` is cheap and read-only.

## Recommendation

| Scope | Suggested `maxDeviationBps` |
|---|---|
| **Global, all liquid pools above** | **100** (1%) — covers every mainnet pool in this snapshot incl. 0.30% tiers, buffer already inside |
| Only ≤0.05% tiers + stables | ~90 (ETH/BTC 0.05% pairs still hit ~88 due to a ~33 bps basis) |
| Conservative (volatility headroom) | 125–150 |

**Caveats**
- **One snapshot.** Basis widens during volatility; before finalizing, run the script repeatedly (incl.
  volatile windows) and take a high percentile — don't set the tolerance off a single quiet reading.
- `maxDeviationBps` is **global** for the oracle; it must cover the *worst pool the managers actually
  trade*. If the pool set is known/narrow, tune to it (a stables-only manager can run much tighter).
- The 50 bps `BUFFER` covers execution slippage for modest sizes; large swaps in thin pools (e.g.
  Arbitrum ARB/USDC) need more.
- 0.30%-fee pools dominate the requirement (fee alone is 30 bps). Prefer routing operator swaps through
  low-fee tiers where possible.

## Sources
- Pool configs: `script/price_pools/{1,8453,42161,130}.json` (per-chain PoolKeys).
- Feeds: `script/oracle_feeds.json`. Script: `script/PriceDeviation.s.sol`.
