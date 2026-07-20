# task_039 — ChainlinkPriceOracle hardening

Follow-up to the `ChainlinkPriceOracle` audit (see the audit notes for full findings). Fixes the
deployment-blocking items before the oracle is wired into operator-swap guards on L2.

## Fixes

- **H-1 — L2 Sequencer Uptime gate.** `check` now consults an optional L2 Sequencer Uptime Feed. While
  the sequencer is **down** (answer != 0) or **within the grace period** after a restart, `check` returns
  `false` (no opinion) ⇒ operator swaps fail-closed. Constructor gains
  `(address sequencerUptimeFeed, uint32 sequencerGracePeriod)` plus an owner `setSequencerFeed`. Zero feed
  ⇒ gate skipped (L1 mainnet, and L2s Chainlink publishes none for, e.g. Unichain).
- **M-1 — staleness underflow.** `_read` now also rejects `updatedAt == 0` and `updatedAt > block.timestamp`
  before the `block.timestamp - updatedAt` subtraction, so a future/invalid feed timestamp yields "no
  opinion" instead of reverting the whole operator tx.
- **L-1 — decimals bound.** `setFeed` rejects `tokenDecimals > 36` (`TokenDecimalsTooLarge`) so
  `10 ** (feedDecimals + tokenDecimals)` in `check` can't overflow-revert a pair.

Residual findings (M-2 min/maxAnswer circuit-breaker, M-3 per-swap tolerance × repetition, L-2
owner-centralization / timelock, L-3/L-4 tolerance tuning) are documented in the audit as accepted /
operational and left for a later pass.

## Deploy wiring

- `DeployStableLP` resolves oracle inputs into an `OracleParams` struct from `chain_params.json`:
  `oracleMaxDeviationBps` (default 100), `oracleSequencerFeed` (optional), `oracleGracePeriod`
  (default 3600). Sequencer feeds wired for base (`8453`) and arbitrum (`42161`) from the official
  Chainlink L2 Sequencer Feeds page.

## Tests

`test/ChainlinkPriceOracle.t.sol`: sequencer up-past-grace / down / within-grace / cleared, the
future-timestamp no-revert case, and the tokenDecimals bound. `test/DeployStableLP.t.sol`: oracle config
parsing (feed + grace) and the `OracleParams` deploy path.

## Verify

```bash
forge test --match-path test/ChainlinkPriceOracle.t.sol -vvv
forge test --match-path test/DeployStableLP.t.sol -vvv
forge build --sizes
```
