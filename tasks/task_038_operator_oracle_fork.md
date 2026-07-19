# Task 038 — Operator + real Chainlink oracle, Base-fork case

Extend the Base-fork suite `test/GasCompareVolatile.fork.t.sol` (task_037) with the **operator path**
gated by the real `ChainlinkPriceOracle` (task_031) against live Base Chainlink USD feeds. Env-gated by
`BASE_RPC`; skips cleanly when unset. Stacked on `task/037-volatile-fork-gas`.

## Why
task_037 only measured **owner-driven** ops (oracle bypassed). The HIGH-risk path (H-VOL-1) is an
**operator** recenter/allocate swap, which is fail-closed behind `IPriceOracle`. This task exercises that
guard end-to-end with a real Chainlink feed on a fork: happy path (oracle vouches), plus both guard
rejections.

## Base Chainlink feeds (USD, 8 dp)
- ETH/USD: `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`
- USDC/USD: `0x458138Fc0D67027E9A6778ef40a6ffC318c69061`

## Design
- **Pool price must track the oracle reference.** `setUp` now initializes the WETH/USDC pool (when it
  does not already exist) at the **ETH/USD feed price**, not a hard-coded tick — otherwise a swap in a
  $3000 pool checked against a $3500 reference trips `PriceOutOfBounds` even on the happy path. Owner ops
  are price-agnostic, so this is safe for the existing task_037 tests.
- `ChainlinkPriceOracle(owner, maxDeviationBps)`; `setFeed(WETH, ethUsd, heartbeat, 18)`,
  `setFeed(USDC, usdcUsd, heartbeat, 6)`. Heartbeat huge (365 days) so the fork-block answer is "fresh"
  and `check` returns `enforced = true`.
- **`test_operator_withChainlinkOracle_gas`** — owner recenter (baseline, oracle bypassed) vs operator
  recenter under a 5% oracle (a small swap: fee-only deviation ≪ 5% → oracle vouches). Logs gas + the
  oracle overhead delta. Asserts both succeed.
- **Guard rejections:**
  - operator swap with **no oracle** → `OperatorSwapGuardRequired`.
  - operator swap under a **tight (10 bps) oracle** → `PriceOutOfBounds` (the 0.3% pool fee alone exceeds
    the tolerance). A tight tolerance stands in for "adverse swap beyond tolerance" — deterministic on a
    fork regardless of live pool depth.

## Verify
```bash
forge build
forge fmt --check
BASE_RPC=https://mainnet.base.org forge test --match-path test/GasCompareVolatile.fork.t.sol -vvv
```
