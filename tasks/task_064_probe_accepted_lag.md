# task_064: the probe fails the v2.2.0 release on a lag the owner chose

## Symptom
GitHub CI for the `v2.2.0` tag and master `ca6d29c` is red. Build and tests pass; the step
"Deployed stack carries every selector of this build" (`probe_deployment.mjs`) exits 1:

```
chain 1301 unichain-sepolia v2.2.0 @7898d9c
  WalletPositionDescriptor 0x24F15fC420ff0773F9e949c9cE3474A696e26608 missing: ART(), MAX_POSITIONS(), WETH(), …
1 deployed component(s) lack selectors master has — the stack is behind.
```

## Cause
Not drift. `chain_params.json` has `deploy.descriptor: false` for 1301 and no `descriptor` block
(WETH, reference pools), so the v2.2 deploy kept the v2.1 descriptor on the testnet on purpose. The
probe had no way to tell a chosen lag from a forgotten one.

## Fix
- `chain_params.json`: per chain `probeAccepted: { <deployments key>: "<reason>" }`; 1301 declares
  `descriptor`.
- `probe_deployment.mjs` still checks an accepted component and prints
  `behind (accepted: <reason>) — missing N selectors`, but it does not fail the run; the summary line
  counts the accepted lags. NO CODE, unreadable RPC and any component without an entry fail as before.
- To clear it: add a `descriptor` block for 1301, set `deploy.descriptor: true`, deploy, and remove the
  entry.

## Verify
`node script/probe/probe_deployment.mjs` → exit 0, 1301 descriptor shown as accepted. `forge test`.
