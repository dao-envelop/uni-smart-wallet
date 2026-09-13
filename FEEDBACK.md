# Feedback on building over Uniswap v4

We built an LP manager that talks to `PoolManager` directly — no periphery `PositionManager` — and
during ETHOnline added `moveLiquidity`: one operator call that moves a position out of one pool and into
another inside a single `unlock`. Here is what cost us time.

**1. Nothing explains why several pools in one `unlock` is allowed.** It works because deltas are keyed
by `(address, currency)` and not by pool, so the exit check doesn't care how many pools you touched. You
can infer that from `currencyDelta(user, currency)` having no pool argument, but no page says it. The
Batch Modify guide states the conclusion — "move liquidity between two positions on entirely different
Pools" — without the reason, which wasn't enough for us to risk real money on it. We ended up reading
`PoolManager._accountDelta` and writing a test against a bare `PoolManager`. One sentence in the Unlock
Callback & Deltas guide would have saved a day.

**2. The swap guides never mention partial fills.** A swap that reaches `sqrtPriceLimitX96` stops there
and returns successfully, having spent less than you asked for. `IPoolManager.swap` does say
"Integrators should perform checks on the returned swapDelta" — but in a note about low liquidity and
hooks, while the swapping guides teach only a minimum-output check, which doesn't catch an exact-input
swap that under-spent.

**3. Contract size is the real constraint, and there's nothing to call into.** Periphery offers the
settle plumbing only as base contracts you inherit, so it becomes your bytecode either way — we ended up
writing our own `_settle` rather than inherit a base we couldn't afford whole. Ours ships with 46 bytes
free of 24,576, and that budget chose our API rather than the use case did: the version taking arrays of
sources and destinations needed 947 bytes and we had 858, so the call moves one position to one
destination. The docs never mention size at all.

**4. A `PoolKey` can't be recovered from any public source.** There's no on-chain read path and no API:
`POST /lp/pool_info` needs the `fee` and `tickSpacing` you were trying to find out. The subgraph does
list a pair's pools, but its `feeTier` is the *effective* fee rather than the key's — on Arbitrum it
reports 625 for a pool whose id only reproduces from 500, and it never carries the key at all for a
pool it has not seen trade. So we probe candidate fee tiers and tick spacings until the hash matches.

**5. The official v4 subgraph drops `salt`.** On chain it's fine — `ModifyLiquidity` carries the pool id
and the salt together. But the subgraph's entity has no `salt` field and its `Position` entity is built
around `PositionManager` token ids, so the documented indexing path can't represent positions keyed by
salt, and everyone who keys them that way writes the same decoder.
