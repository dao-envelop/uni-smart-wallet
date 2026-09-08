# Feedback on building over Uniswap v4

Written while adding `moveLiquidity` to `VolatileLPManager` — one operator call that pulls liquidity
from one pool and adds it into another inside a single `unlock`. Everything below is something that
cost us time on this integration, not a wish list.

**1. Deltas are keyed by `(address, currency)`, not by pool — and nothing says so.** That is what makes
several pools legal inside one `unlock`, which is the whole basis of the operation we shipped. Nothing
in the docs states it, and the intuition every integrator arrives with is pool-scoped. We only believed
it after reading `PoolManager._accountDelta` and writing a standalone test
([`test/CrossPoolUnlock.t.sol`](./test/CrossPoolUnlock.t.sol)) against a bare `PoolManager` to prove
that a two-pool callback settles. One sentence in the `unlock` documentation would have saved a day.

**2. `unlock` checks exactly one thing on exit** — `NonzeroDeltaCount != 0`. Same root as (1): the
guarantee is stronger and simpler than it looks, and stating it plainly ("any number of pools, any
order, as long as you leave no non-zero delta") would let people design against it instead of guessing.

**3. `modifyLiquidity` returns `(callerDelta, feesAccrued)` — removing liquidity realises fees.** Easy
to read past, and expensive when you do: our claim path reported realised fees and our removal paths did
not, so a recenter silently reset lifetime fee counters for everything downstream. The docs describe the
return as a delta pair; that the second element means "fees you just took, whether or not you asked" is
the part worth saying out loud.

**4. A `swap` can fill partially** when it reaches `sqrtPriceLimitX96`, and the caller has to notice.
Writing a full-fill guard by hand is not what you expect to do after an exact-input swap returns
successfully; an explicit "check this yourself" in the swap docs would set the expectation.

**5. EIP-170 is the real constraint for managers built over v4, and there is no periphery to lean on.**
Our largest manager ships with 144 bytes of headroom. The first version of this operation took an array
of pulls and an array of adds; the calldata-to-memory encoder and memory decoder that arrays of structs
require cost **947 bytes against 858 of headroom**, so the API became one position to one destination —
a shape chosen by the size limit, not by the use case. Along the way we were trading a `virtual`
modifier for a `pure` predicate to recover 9 bytes. Periphery that could hold shared unlock/settle
plumbing as an external library would change what integrators can build.

**6. There is no canonical way to ask "which pools exist, and with what liquidity".** Discovery needs a
subgraph or an indexer, and the explore gateway returns the *effective* fee rather than the `PoolKey`
fee, so a `PoolKey` cannot be reconstructed from it — we recover the key by probing candidate fee tiers.
A read path for "pools for this pair, with their keys" would remove a class of workarounds.

**7. Nothing links a position's `salt` to its pool on chain.** `salt` is chosen by the caller and lives
only in the manager's storage, so an indexer has to read Uniswap's own `ModifyLiquidity` logs to learn
which pool a position is in — the manager's own events cannot describe it. That is defensible, but it
means every integrator that keys positions by salt ends up building the same reconstruction.

Where the code lives: [`src/VolatileLPManager.sol`](./src/VolatileLPManager.sol) (`moveLiquidity`, its
`_handleMove` handler and `_guardedSwap`, the one swap path allocate, recenter and move share),
[`test/VolatileLPManagerMove.t.sol`](./test/VolatileLPManagerMove.t.sol) (behaviour, oracle matrix, the
"nothing leaves the manager" check and the gas benchmark) and
[`test/CrossPoolUnlock.t.sol`](./test/CrossPoolUnlock.t.sol).
