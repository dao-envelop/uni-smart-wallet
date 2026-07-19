# Task 037 — VolatileLPManager Base-fork gas benchmark + recenter vs manual rebalance

New fork test `test/GasCompareVolatile.fork.t.sol` against the **live Base v4 PoolManager** (chainId
8453). Env-gated by `BASE_RPC` (+ optional `BASE_FORK_BLOCK`); skips cleanly when unset.

## What it does
- Uses a fresh hookless **WETH/USDC** pool (initialized at a ~$3000/ETH tick if it doesn't already exist),
  seeded with a wide background LP so the rebalancing swaps have real depth.
- **`test_volatile_managerOps_gas`** — measures gas on every VolatileLPManager op: `createManager`,
  `allocate`, `claimFees`, `recenter`, `withdrawTo` (owner-driven, so no oracle needed).
- **`test_recenter_vs_manualRebalance`** — compares `VolatileLPManager.recenter` (one call: remove → swap →
  re-add) against the equivalent **manual rebalance** via the Uniswap v4 **PositionManager** + swap router
  (decrease → swap → mint), logging the gas delta.
- **`test_smoke_baseLive`** — asserts the Base v4 / token addresses have code.

Base addresses (verified against developers.uniswap.org/contracts/v4/deployments): PoolManager
`0x498581fF…`, PositionManager `0x7C5f5A4b…`, Permit2 `0x0000…78BA3`, WETH `0x4200…0006`, USDC
`0x833589fC…`.

## Result (validated live on Base, latest block)
| op | gas |
|---|---|
| createManager | ~405k |
| allocate | ~332k |
| claimFees | ~136k |
| recenter | ~172k |
| withdrawTo | ~136k |

`recenter` (~178k, one call) vs manual PositionManager decrease+swap+mint (~329k): **recenter is ~151k
(~46%) cheaper**.

## Verification
```bash
forge build
forge test                                     # fork test skips without BASE_RPC (0 failures)
BASE_RPC=https://mainnet.base.org forge test --match-path test/GasCompareVolatile.fork.t.sol -vvv
```
</content>
