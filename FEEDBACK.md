# Feedback on building over Uniswap v4

Written while adding `moveLiquidity` to `VolatileLPManager` — one operator call that pulls liquidity from
one pool and adds it into another inside a single `unlock`. Everything here cost us time.

**1. Deltas are keyed by `(address, currency)`, not by pool — and nothing says so.** That is what makes
several pools legal inside one `unlock`, which is the whole basis of what we shipped. We only believed it
after reading `PoolManager._accountDelta` and proving it against a bare `PoolManager`
([`test/CrossPoolUnlock.t.sol`](https://github.com/dao-envelop/uni-smart-wallet/blob/master/test/CrossPoolUnlock.t.sol)). One sentence in the docs saves a day.

**2. `unlock` checks exactly one thing on exit** — `NonzeroDeltaCount != 0`. Same root as (1): the
guarantee is stronger than it looks. Say it plainly — any number of pools, any order, leave no non-zero
delta — and people design against it instead of guessing.

**3. `modifyLiquidity` returns `(callerDelta, feesAccrued)` — removing liquidity realises fees.** Our
claim path reported them, our removal paths did not, so a recenter silently reset lifetime fee counters
downstream. "Fees you just took, whether or not you asked" is worth saying out loud.

**4. A `swap` can fill partially** at `sqrtPriceLimitX96`. Writing a full-fill guard by hand is not what
you expect after an exact-input swap returns successfully; "check this yourself" in the docs would do.

**5. EIP-170 is the real constraint, and there is no unlock/settle plumbing callable as an external
library** — periphery's `LiquidityAmounts` helps with the math, but bytecode is what runs out. Our largest
manager ships with **46 bytes of headroom** (24,530 of 24,576). The first version of this operation took
an array of pulls and an array of adds; the calldata-to-memory encoder and memory decoder that arrays of
structs require cost **947 bytes against the 858 we had before the operation**. So the API is one position
to one destination — a shape chosen by the size limit, not by the use case.

**6. There is no canonical way to ask "which pools exist, with what keys".** Discovery needs a subgraph or
an indexer, and the explore gateway omits `tickSpacing` and on some chains reports the *effective* fee
rather than the `PoolKey` fee — so both key fields get recovered by probing candidates. "Pools for this
pair, with their keys" would remove a class of workarounds.

**7. Nothing links a position's `salt` to its pool in logs.** `salt` is caller-chosen and the pool lives
only in manager storage, so a log-only indexer must read Uniswap's own `ModifyLiquidity` events to learn
which pool a position is in. Defensible, but every integrator keying positions by salt rebuilds it.
