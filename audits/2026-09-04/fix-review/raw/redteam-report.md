# Red team vs task_053 — raw agent report (empirical, worktree agent-a0413cd9d7f508e84)

Setup: worktree at `audit/2026-09-04` HEAD `a96ea5a`, submodules initialised, `forge build` OK,
`forge fmt --check` clean, full suite 316 passed / 0 failed / 4 skipped with the 23 new PoCs added.
All PoCs use the REAL `ChainlinkPriceOracle` with `MockAggregator` feeds, never `MockPriceOracle`.
Sources preserved in `../poc/RedTeam*.t.sol`. Run: `forge test --match-path "test/RedTeam*" -vv`.

## F1 — HIGH (product-scoped): a hook restores H-1 in full on OpenVolatileLPManager

PoC `test_T2_hookWarpsPriceAfterTheOracleVouched`.

The guard sits at `src/VolatileLPManager.sol:288`; the add is priced at `:293`. In between, v4 calls
`hook.beforeAddLiquidity` (`PoolManager.sol:156` runs the hook, `:159` runs `pool.modifyLiquidity`).
The lock is still open, so the hook may re-enter `PoolManager.swap`, move the price and settle its own
deltas. The oracle's vouch describes a price that no longer exists when v4 computes what the manager owes.
The hook needs NO delta-returning permission — only `BEFORE_ADD_LIQUIDITY_FLAG | AFTER_ADD_LIQUIDITY_FLAG`.

Measured (2 000e18 portfolio, 1:1 reference, 0.01 % pool, spacing 1):

| | |
|---|---|
| oracle vouch before the call | `check(key,true,0,0) == true`, pool exactly on reference |
| manager value before / after | 2 000e18 -> 1 100.06e18 |
| loss in one vouched-for call | 899.94e18 = 44.997 % of portfolio |
| hook gain | 899.37e18 (99.94 % transfer) |
| control, identical call, hook idle | -1 wei |
| two calls (`test_T2_repeatable`) | 2 000 -> 1 595 -> 1 190e18 |

The skew is unbounded — `maxSpotDeviationBps` never sees it. Collateral: `test_T2_ownedExceedsDesired`
breaks the `_addLiquidityAt` docstring invariant "owed <= the desired amounts by construction" — a leg
with `amount1Desired == 0` made the manager spend 999.95e18 of currency1.

Doc defect: `src/OpenVolatileLPManager.sol:26-50` enumerates accepted residuals 1-3 and then states
"What is NOT on that list, despite hooks now running inside our `unlock`: re-entrancy." That is wrong for
the add path. It also calls the oracle guard "inherited unchanged", implying it works. CLAUDE.md repeats it.

Mitigating, verified (`test_T2_hooklessProductHasNoSuchWindow`): Stable/Volatile keep
`_hooksAllowed() == false` (`src/BaseLPManager.sol:242`), so `key.hooks == address(0)` and there is no
callback to warp from. The hookless products are immune by construction.

Deploy impact: `script/RUNBOOK-2026-09-05.md` excludes `OpenVolatileLPManager` (`openImpl: false`).
Does not block this run; must block any future Open deploy.

## F2 — HIGH: the residual is bounded per operation and unbounded in total

PoCs `test_T1a` / `test_T1c` / `test_T1d`.

Staying inside the gate: skew to tick +49 (+49.12 bps, tolerance 50), swapless `recenter` into the
narrowest legal range at that price, trade back to the OPPOSITE edge of the band. The return leg lands at
-49 bps, which is the setup for the next operation — the skew is paid for once and harvested forever.

| measurement | value |
|---|---|
| loss per operation (fee 100, spacing 1) | 47.38 bps of portfolio; attacker gains 47.12 bps |
| control: same price path, no operator op | manager +2 bps (it earns fees) |
| 40 operations, 40 transactions | 17.33 % drained |
| 60 operations in ONE transaction (contract operator) | 24.84 % drained, 29.5 M gas |

`nonReentrant` does not bite — the calls are sequential, not nested. No cooldown, no per-epoch cap, no
value floor. ~490 k gas/op => ~60 ops per Ethereum block, far more on Unichain/Arbitrum.

Corrected residual formula: achieved value is `maxSpotDeviationBps - tickSpacing/2 - poolFee`.

| tick spacing | aligned range | predicted | measured |
|---|---|---|---|
| 1 | [48,49], mid 48.5 | 47.5 | 47 |
| 10 | [30,40], mid 35 | 34 | 33 |
| 50 | [-50,0] — cannot reach the band | <=0 | 0 |
| 200 | [-200,0] | <=0 | 0 |

Fee tier sweep: 0.01 % -> 47 bps, 0.05 % -> 29 bps, 0.30 % -> 0, 1 % -> 0. The attack is confined to
`tickSpacing <= 10` (the 100 and 500 tiers).

Who pays the fee: the attacker pays it and the manager, as the in-range LP, receives most of it back —
so the `- poolFee` credit is genuine, and it is why higher tiers are safe.

Pool depth (manager principal 1 000e18): manager loss is DEPTH-INDEPENDENT, 47 bps every time. The
attacker's profit is not: 4.73e18 at 2 000e18 pool liquidity, 4.60e18 at 20 k, 3.39e18 at 200 k, and a
LOSS of 8.74e18 at 2 000 000e18. Break-even ~500-700x the manager's principal. On deep pools the attack is
unprofitable but still fully destructive — a hostile operator burns the portfolio at 47 bps a call.

Verdict: task_053 is a large improvement (44.5 % in one call -> 0.47 %), but it converted an instant theft
into a fast bleed, not into a bounded one. H-1 is REDUCED, not fixed. Missing: a rate or value control.

## F3 — MEDIUM: the fix hands a third party a cheap operator-DoS lever that did not exist before

PoCs `test_T3a` / `test_T3b` / `test_T3c`. The gate is fail-closed and reads live `slot0`
(`src/oracle/ChainlinkPriceOracle.sol:284`). Anyone who moves the pool 51 bps switches off every operator
liquidity op in that pool; `recenter` and `allocate` both revert `SpotPriceOutOfBounds`.

Cost of blocking ONE operator transaction (skew + unskew at the reference price):

| pool liquidity (fee 0.01 %) | griefer net cost |
|---|---|
| 4 000e18 | 0.063e18 (3 bps of a 2 000e18 portfolio) |
| 400 000e18 | 0.30e18 |
| 40 000 000e18 | 24.06e18 |

| fee tier (400 000e18 pool) | griefer net cost |
|---|---|
| 0.01 % | 0.34e18 |
| 0.05 % | 1.72e18 |
| 0.30 % | 8.88e18 |

Cost ~ 2 x fee x depth x 60 bps. On the thin pools where F2 lives, blocking the bot indefinitely is
essentially free. Before the fix no such lever existed. Mitigant, verified in the same test: the owner
bypasses the guard and can still recenter — the DoS hits automation only, not custody.

Related operational risk: many Chainlink USD feeds have a 0.5 % deviation threshold, i.e. the reference is
DESIGNED to be up to ~50 bps stale. With `oracleMaxSpotDeviationBps: 50` on all five chains an honest pool
will routinely sit at the band edge and the bot fails closed with no attacker at all.

## F4 — MEDIUM: an operator's own oracle-approved pre-swap makes its own add revert

PoCs `test_T4a`-`test_T4d`. Sweep on a 1 000 000e18 pool, fee 0.01 %:

| pre-swap in | as bps of pool liquidity | resulting tick | recenter reverts? |
|---|---|---|---|
| 500e18 | 5 | -10 | no |
| 1 000e18 | 10 | -20 | no |
| 2 000e18 | 20 | -40 | no |
| 2 500e18 | 25 | -50 | no |
| 3 000e18 | 30 | — | YES |
| 5 000e18 | 50 | — | YES |

Threshold ~25-30 bps of the pool's virtual liquidity. `test_T4b`: the identical 3 000e18 trade realises a
28 bps shortfall against the reference — the SWAP branch returns true at a 100 bps tolerance, ~3.5x of
margin — while the SPOT branch refuses the -55 tick price that same trade produced.
`test_T4d` multi-leg: legs 0 and 1 succeed, leg 2 reverts `SpotPriceOutOfBounds` on the drift the earlier
legs caused. `_handleAllocateV` has no notion of cumulative drift.

## F5 — LOW: the sentinel's stated safety argument is false at one of its call sites

`ChainlinkPriceOracle.check:246` argues the `amountIn == 0` sentinel is unreachable from a real swap
because every swap path has already required the realized input to be no smaller than the requested one.
That full-fill check exists in `VolatileLPManager._guardedSwap:225` and `StableLPManager._allocateLeg:189`.
It does NOT exist in `StableLPManager._handleReinvest:292-299`, which calls `_guardSwap` with raw realized
deltas and no fill requirement.

`test_T5d` proves the enabling mechanism: a v4 exact-in swap can realise ZERO input and zero output while
still moving the price, because `Pool.swap`'s loop has no zero-liquidity guard (`Pool.sol:344-368` —
`computeSwapStep` with `liquidity == 0` returns zeros and advances the price to the target for free).
Measured: tick 0 -> 500, `amount0 == 0`, `amount1 == 0`. Fed to `_guardSwap` that is exactly `(0, 0)`.

No loss was constructed: a zero-fill swap moves no value and the subsequent add is still spot-gated.
Defence-in-depth is broken; the exploit is not there. One-line fix: copy the `SwapSlippage` check from
`StableLPManager.sol:189` into the reinvest path.

## F6 — INFORMATIONAL: an ERC-721 approval on the manager is a total bypass

`test_T5b`. `byOwner` comes from `_isOwnerCall` (`src/BaseLPManager.sol:339`), a strict
`ownerOf(TOKEN_ID) == msg.sender`; `setOperator` can never produce it. But the manager IS the ERC-721:
`setApprovalForAll(bot, true)` lets the bot `transferFrom` the token to itself, after which it is the
owner — the gate is gone and `withdrawTo` is open. Worth an explicit warning in the UI/docs given the
operator address is a hot key.

## Negative results (attempted, blocked, with the check named)

- No add path reaches `modifyLiquidity` with a positive delta without passing the guard. `test_T5a`: with
  `priceOracle` cleared, operator `allocate`, `recenter` and `moveLiquidity` all revert
  `OperatorSwapGuardRequired`. The remaining `modifyLiquidity` sites all pass `liquidityDelta <= 0`:
  `VolatileLPManager.sol:159`, `StableLPManager.sol:258`, `:286`, `BaseLPManager.sol:490`.
- An operator cannot make `byOwner` true — blocked by `_isOwnerCall:339` (see F6 for the adjacent footgun).
- `check` cannot return true for a skewed pool. `test_T5c`: an oracle built against a different
  PoolManager reads the pool as uninitialized and returns false; the operator fails closed.
- H-1 cannot be restored on the hookless products: nothing can execute between the guard and
  `pool.modifyLiquidity` when `key.hooks == address(0)`.
