# Lens probe

`probe_lens.mjs` — post-deploy verification for the redeployed `UniLens` (task_040).

- Confirms the `lens` address in each `deployments/<chainId>.json` (1 / 130 / 1301 / 8453 / 42161)
  has code on-chain.
- Calls `managerFull()` against the Arbitrum volatile manager `0x60723973ABF3BBC2ce7EB4400B728390D55e264b`
  and asserts the task_040 acceptance criteria (pools = 4, managed `[ETH, USDC, WBTC]`, one funded
  unmanaged `USD*` stable at `25_000000`, `oracleType == 3001`, descriptor set, live `sqrtPriceX96 != 0`).
  `priceOracle` is reported as an observation, not a hard check (it is manager config, not a lens property).

## Run

`viem` is not a dependency of this Foundry repo. Resolve it from any project that has it — e.g. the
sibling `stablelp-ui` dApp:

```bash
ln -s ../../../stablelp-ui/node_modules script/probe/node_modules   # one-off, git-ignored
node script/probe/probe_lens.mjs
```

Public RPCs are used by default; override per chain via `RPC_1` / `RPC_130` / `RPC_1301` / `RPC_8453` /
`RPC_42161`. The ABI in `unilens_abi.json` is the `managerConfig`/`managerFull` slice of the compiled
`UniLens` ABI.
