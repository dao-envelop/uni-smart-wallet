# task_062: retire superseded manager impls at deploy

## Symptom
The v2.2 deploy only blesses the new impls on the existing factory. The v2.1 impls (affected by the
operator round-trip drain, task_060) and the v2.0 ones stay allowlisted. Anyone can keep cloning
vulnerable managers through the factory: the UI's old code paths, the MCP, a script.

Checked on 2026-10-21: `isImplementation` is `true` on the v2.0 impls on all four chains:

| Chain | v2.0 impl |
|---|---|
| 1 | `0x5a44…43Bb` |
| 130 | `0x71B7…D06D` |
| 8453 | `0x9C10…27b7` |
| 42161 | `0x7f37…C4a2` |

## Fix
`DeployStableLP.s.sol`:
- `deploy.revokeReplaced`. After the fresh impls are allowlisted, the script revokes the ones they replace: `.impl`, `.volatileImpl` and `.openImpl` from `deployments/<chainId>.json`.
- Per-chain `revokeImpls: [..]` covers older releases.
- Both are owner-only. They skip with a WARN otherwise and never touch this run's fresh impls.
- Clones that already exist are unaffected: `isImplementation` gates creation only. Nothing in stablelp-ui, the MCP or insight reads it.

`chain_params.json`: `revokeReplaced: true` for 1/130/8453/42161/1301, and the v2.0 impls above in `revokeImpls`.

## Verification
- Tests: `test_revokeReplacedImplsAfterBlessingFreshOnes` and `test_revokeReplacedOffOrNotOwnerKeepsOldImpls`. `forge test`: 398 passed, 0 failed, 7 skipped.
- Fork dry-run of `DeployStableLP` without `--broadcast` on 42161/8453/130/1. On each chain it blesses 2 fresh impls, then revokes v2.1 stable + volatile and the listed v2.0 impl.
