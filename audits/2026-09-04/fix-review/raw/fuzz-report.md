# Differential fuzz of the spot branch — raw agent report (worktree agent-ad015eddaad2acce4)

Method: an INDEPENDENT model in exact rational arithmetic (Python `Fraction` over the definitions
`poolPrice = sqrtP^2 * 10^td0 / (2^192 * 10^td1)`, `refPrice = a0 * 10^fd1 / (a1 * 10^fd0)`), never a second
copy of the Solidity expression. `test_differentialSweep_negativeControl` passes, proving the assertions
bite. Sources preserved in `../poc/ChainlinkPriceOracleSpotFuzz.t.sol` and `../poc/ffi/spot_exact.py`.
Run: `forge test --match-path 'test/ChainlinkPriceOracleSpotFuzz.t.sol' -vv` => 12 passed, 6 failed;
each failure is a demonstrated defect.

## 1. MEDIUM (latent) — the gate's price resolution is coarser than its own tolerance

`src/oracle/ChainlinkPriceOracle.sol:289-296`. Three integer truncations stack. `priceX96` is an integer,
so resolution is `1e4/priceX96` bps; `poolPrice`/`refPrice` are `humanPrice * 1e18` as integers, a second
floor of `1e4/refPrice` bps. Nothing checks either against `maxSpotDeviationBps`. Truncation is
one-directional, so the accepted corridor does not merely widen — it SHIFTS off the reference, and the
pool price is understated, dragging an over-priced pool into the corridor.

Measured (tolerance 50 bps):

| configuration | largest deviation ACCEPTED | smallest REJECTED |
|---|---|---|
| td0=27, td1=0, both assets $1 | 96.5 bps | 28.9 bps |
| td0=18, td1=6, currency0 at $1e-16 | 1358.7 bps (tick +1275) | — |
| td0=18, td1=6, fd0=18, fd1=6, a0=7440, a1=1e8 | nothing accepted in +-2200 ticks | 0.648 bps — total DoS |
| decimal-gap scan, priceX96~79 | gap <= 8 safe; gap 9-10 -> 201.0 bps; gap >= 12 -> 95.5 bps | |
| price-ratio scan, both sides 18 dec | ratio >= 1e-14 correct; 1e-15 -> 59.2; 1e-16 -> 98.5; 1e-17 -> 303.5 | 1e-16 and below: 0.96 bps rejected |

Two independent triggers, either sufficient: `td0 - td1 >= 9` with a human price low enough that
`priceX96 < 1e4/tol`; or `usd0/usd1 < ~2e-15` at any token decimals.

Reachability (independently re-derived): all four `script/oracle_tokens/*.json` configure only 6/8/18
decimals. For the worst realistic gap (18 vs 6) the trigger needs currency0 below $2.5e-15. Latent
config-dependent hole, not a live exploit — but `setFeed` accepts `tokenDecimals` up to 36 and any
positive answer with no sanity check.

Fix: require the comparison to have resolution, e.g. `if (priceX96 < 1e6 || poolPrice < 1e6 || refPrice <
1e6) return false;` — or compare in Q96 space throughout, dropping the WAD round-trip.

## 2. LOW — MAX_TOKEN_DECIMALS = 36 is not safe on every path; the headroom comment is wrong

`src/oracle/ChainlinkPriceOracle.sol:94-100`. The comment reasons about the DENOMINATOR
`Q96 * 10 ** tokenDecimals` ("room up to 48"). The binding constraint is the RESULT of line 290:
`poolPrice == humanPrice * 1e18` overflows once `humanPrice > ~1.16e59`.

Measured: with `td0=36, td1=0`, tick 531 088 is the first tick at which `FullMath.mulDiv`'s
`require(denominator > prod1)` fires — inside `MAX_TICK = 887 272`. At `MAX_TICK-1`: td0 in {0,6,12,18}
gives a clean `SpotPriceOutOfBounds`; td0 in {27,36} gives a REVERT WITH EMPTY RETURNDATA — neither the
custom error nor the documented "no opinion" false. `MIN_TICK` correctly returns false.
(Independently re-derived: overflow tick 531 087 for (36,0); 738 330 for (27,0); 1 083 735 for (18,6),
i.e. beyond MAX_TICK and therefore unreachable on realistic decimals.)

Fix: lower `MAX_TOKEN_DECIMALS` to ~24, or degrade an overflow to `return false`.

## 3. LOW — two unprotected operations on line 292 give Panic(0x11) instead of "no opinion"

`uint256 refPrice = FullMath.mulDiv(a0, (10 ** fd1) * WAD, a1 * (10 ** fd0));` is the only price
expression not fully inside `mulDiv`.
- `a1 * (10 ** fd0)` is a plain checked multiply. `test_panic_refPriceDenominatorOverflows`
  (fd0=18, a1 = type(uint256).max / 1e17) -> Panic 0x11. A misbehaving feed bricks the whole spot path.
- `(10 ** fd1) * WAD` overflows for `fd1 >= 60`. `feedDecimals` is read straight off the aggregator and,
  unlike `tokenDecimals`, is never bounded. `test_panic_feedDecimalsUnbounded` (fd1=60) -> Panic 0x11.
  The same shape pre-exists in the swap branch at line 264 (`10 ** (fdOut + tdOut)` panics at 78).

Fix: bound `fd` in `setFeed`, and split line 292 into two mulDiv steps or guard `a1`.

## 4. INFO — measured asymmetry of normalising by refPrice

| tolerance | widest tick accepted up | widest tick accepted down | up edge vs poolPrice | down edge vs poolPrice |
|---|---|---|---|---|
| 50 bps | +50 (+0.5012 %) | -51 (-0.5087 %) | 0.4987 % | 0.5113 % |
| 1000 bps (cap) | +954 (x1.1001) | -1054 (/1.1112) | 9.10 % | 11.12 % |

At the cap a pool skewed down may sit 1.22x further from the reference than one skewed up. At 50 bps the
asymmetry is 1.03x (immaterial). The NatSpec "in either direction" is imprecise at the cap.

## 5. INFO — the final floor grants up to <1 bps of extra tolerance

`mulDiv(diff, 10_000, refPrice) > maxSpotDeviationBps` floors before comparing, so an exact deviation in
[tol, tol+1) bps is accepted. Measured: 50.87 bps accepted at 50; 1000.94 bps at the cap.

## 6. Clean negative — the math is correct across the whole realistic domain

`test_roundingError_ordinaryDecimals`, decimal pairs (18,18), (18,6), (6,18), (8,18), (18,8), (6,6),
answers $0.01 to $60 000, +-60 ticks across the boundary: worst boundary disagreement vs the exact model
0.894 bps, entirely accounted for by the floor above. No fail-open, no fail-closed, no panic, no overflow
in that region. The decimal adjustment, the two-step split at line 290 and the symmetric diff at :295 are
correct. `priceX96 == 0` / `poolPrice == 0` at MIN_TICK correctly yields false.

Coverage executed: ticks MIN_TICK, MIN_TICK+1, +-400 000, MAX_TICK-1, MAX_TICK-2 plus +-{0,1,25,49,50,60}
around the parity tick of every configuration; token decimals {0,6,8,18,27,36} x {0,6,8,18,27,36} (all 36
pairs); feed decimals {6,8,18} and the unbounded case 60; answers from 1 to 2^256/1e17; the 50 bps and
1000 bps tolerances; plus a 48-run fuzz that found its own counterexample on the first fresh seed.
