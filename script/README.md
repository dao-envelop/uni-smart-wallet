## Deploy log
### Unichain Sepolia
```shell
$ #Deploy Implemenation
$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url unichain-sepolia --account three --sender 0x97ba7778dD9CE27bD4953c136F3B3b7b087E14c1 --broadcast --verify

$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url unichain --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify

$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url arbitrum --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify

$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url base --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify

$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url mainnet --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify




$ cast send "$TARGET" "setPositionDescriptor(address)" "0xa950991F86eF1b79Db65c4F3893dA9408A1ce157"  --rpc-url unichain --account maxsiz --sender 0xB72993EbB94dc20E4140AFc99A4BC5E42D3d93B2


$ forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url unichain-sepolia --account three --sender 0x97ba7778dD9CE27bD4953c136F3B3b7b087E14c1 --broadcast --verify

$ forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url unichain --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify

```
# Deploy scripts

Per-chain parameters live in `chain_params.json`, keyed by `block.chainid`. Deploy
artifacts (addresses) are written to `deployments/<chainId>.json`.

| Script | What it does |
|---|---|
| `DeployStableLP.s.sol` | Deploys the LP-manager stack — the FULL set (`FeeRedeemer`, `StableLPManager` + `VolatileLPManager` impls, universal `LPManagerFactory`, `UniLens`, `WalletPositionDescriptor`) **or an arbitrary subset** (e.g. only the oracle + manager impls) selected via a per-chain `deploy` object. Adds the `ChainlinkPriceOracle`. Merges addresses into `deployments/<chainId>.json`. |
| `DeployDescriptor.s.sol` | Deploys **only** a `WalletPositionDescriptor` and updates `.descriptor` in `deployments/<chainId>.json`. |
| `CreateManager.s.sol` | Clones one manager (Stable **or** Volatile) via the universal factory. |

### Selective deploy — the `deploy` toggle

`DeployStableLP` deploys the FULL legacy set when a chain entry has **no** `deploy` object (backwards
compatible). To deploy only a subset, add a `deploy` object of per-component booleans to the chain entry
in `chain_params.json`. **A missing flag defaults to `false`.** Components: `feeRedeemer`, `stableImpl`,
`volatileImpl`, `factory`, `lens`, `descriptor`, `oracle`.

```jsonc
"8453": {
  "name": "base",
  "poolManager": "0x498581fF718922c3f8e6A244956aF099B2652b2b",
  "initialOwner": "0x....",         // protocol admin (owner of FeeRedeemer / factory / oracle)
  "treasury": "0x....",             // optional: FeeRedeemer to pass to impls when it isn't redeployed
  "oracleMaxDeviationBps": 100,     // optional: ChainlinkPriceOracle initial tolerance (default 100 = 1%)
  "deploy": {                       // deploy ONLY the oracle + the two manager impls this run
    "oracle": true,
    "stableImpl": true,
    "volatileImpl": true,
    "feeRedeemer": false,
    "factory": false,
    "lens": false,
    "descriptor": false
  }
}
```

Dependency resolution:

- **Treasury for the impls** (when `feeRedeemer: false`): `treasury` from config → else `.feeRedeemer`
  from the existing `deployments/<chainId>.json` → else revert `TreasuryMissing`.
- **Factory allowlist**: when `factory: true` it blesses whichever impls are available (fresh this run,
  else `.impl`/`.volatileImpl` from the deployments file). When `factory: false` but fresh impls were
  deployed, the script best-effort calls `setImplementation` on the existing `.factory` **only if the
  broadcaster is the factory owner** — otherwise it logs a warning and you allowlist manually.
- **Oracle** is standalone: deployed + recorded under `.oracle`, then wired into each manager clone later
  via the owner-only `setPriceOracle` (see below) — this script does not wire it.

Output is **merged**: only the keys for components deployed this run are (over)written; every other
previously-recorded address in `deployments/<chainId>.json` is preserved.

```bash
# With a "deploy" block set on the target chain, the same command deploys just that subset:
forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url $RPC \
  --sender $SENDER --account $KEYSTORE --broadcast --verify
```

### Chainlink feeds — `oracle_feeds.json`

`script/oracle_feeds.json` holds verified Chainlink **USD aggregator proxies** for the chains that
currently have a deployed stack — `1` mainnet, `8453` base, `42161` arbitrum, `130` unichain, `1301`
unichain-sepolia (the only ones with a `deployments/<id>.json`). Structure: `chainId → SYMBOL →
{ pair, aggregator, feedDecimals, heartbeat }`. Addresses were pulled from Chainlink's official
`reference-data-directory` (2026-07).

Two things to keep in mind when wiring these into the oracle:

- **`setFeed` is keyed by the managed TOKEN address, not by symbol.** The file maps *asset symbol →
  aggregator*; you supply the token's on-chain address (from the manager's pool config) and the token's
  own `decimals` as `tokenDecimals`. One BTC/USD feed serves WBTC, cbBTC, etc.
- **`heartbeat` is the feed's max staleness; the oracle rejects a reference older than it.** Several
  feeds have short heartbeats (Arbitrum USDC/USDT `255s`, mainnet BTC/ETH `3600s`). The guard uses
  `block.timestamp - updatedAt > heartbeat` ⇒ *no opinion* ⇒ operator swaps fail-closed. Consider
  passing a **padded** heartbeat to `setFeed` (e.g. official × 2–3) so a normal update lag doesn't
  spuriously block operators. `130` unichain feeds are **18-decimal SVR** variants (BTC/ETH/UNI only as
  SVR proxies) — review before mainnet use.

### Wiring the price oracle (per manager clone)

`setPriceOracle(address)` points a manager clone at the deployed `ChainlinkPriceOracle` so operator-
triggered swaps are price-guarded (owner swaps bypass). It is `onlyOwnerNFT`. First register each managed
currency's USD feed on the oracle (`setFeed`, owner-only) using `oracle_feeds.json`, then point the
manager at the oracle:

```bash
CHAIN_ID=8453
ORACLE="$(jq -r .oracle deployments/$CHAIN_ID.json)"

# Example: register WBTC (18-dec token) against the BTC/USD feed, heartbeat padded 2×.
cast send "$ORACLE" "setFeed(address,address,uint32,uint8)" \
  "$WBTC_TOKEN_ADDR" \
  "$(jq -r '."'$CHAIN_ID'".BTC.aggregator' script/oracle_feeds.json)" \
  2400 8 \
  --rpc-url "$RPC" --account "$KEYSTORE" --from "$SENDER"

# Then point the manager (clone) at the oracle:
cast send "$TARGET" "setPriceOracle(address)" "$ORACLE" \
  --rpc-url "$RPC" --account "$KEYSTORE" --from "$SENDER"
```

### CreateManager — universal factory

`LPManagerFactory.createManager(implementation, expectedOwner, initData)` clones an **allowlisted**
implementation and forwards the product's `initialize(InitParams)` as raw calldata (the two products'
`initialize` selectors differ), then checks the singleton NFT landed on `expectedOwner`. `CreateManager`
builds all of this from the config JSON: set `"product": "stable"` (default) or `"product":
"volatile"`, and it reads `.impl` / `.volatileImpl` + `.factory` from `deployments/<chainId>.json`.
Volatile configs omit `.tickLower` / `.tickUpper` (ranges are per-call). See
`script/manager_config.example.json` (stable) and `script/manager_config.volatile.example.json`.

## Deploy the descriptor standalone

To ship a new `WalletPositionDescriptor` (e.g. after a rendering change) without redeploying the
whole stack — which would also redeploy the factory/impl/treasury and orphan existing clones —
run `DeployDescriptor`. It has no constructor args, deploys just the descriptor, and rewrites the
`.descriptor` key in `deployments/<chainId>.json` (other keys are preserved; a minimal file is
created if none exists).

```bash
forge script script/DeployDescriptor.s.sol --sig "run()" \
  --rpc-url $RPC --account $KEYSTORE --sender $SENDER --broadcast --verify
```

Then wire the new address into each wallet/manager with the `cast` command below.

## Wiring the position descriptor

`setPositionDescriptor(address)` points a `StableLPManager` / `VolatileLPManager` at a
deployed `WalletPositionDescriptor`, so `tokenURI(1)` renders the position portfolio. It
is `onlyOwnerNFT` (caller must hold the singleton NFT) and is called once after deploy.

The descriptor is deployed once per chain by `DeployStableLP` and shared across every
manager — its address is in `deployments/<chainId>.json` under `.descriptor`. The
target manager address is printed at deploy time (`CreateManager` logs it) and is not
persisted, so pass it explicitly.

```bash
# TARGET = the StableLPManager / VolatileLPManager (clone) address printed at deploy.
# Caller (--account) MUST hold the singleton NFT (onlyOwnerNFT).
CHAIN_ID=8453   # e.g. Base
TARGET=0x...    # wallet / manager address

cast send "$TARGET" "setPositionDescriptor(address)" \
  "$(jq -r .descriptor deployments/$CHAIN_ID.json)" \
  --rpc-url "$RPC" --account "$KEYSTORE" --from "$SENDER"
```

Verify (returns a base64 `data:application/json` URI once set, empty string before):

```bash
cast call "$TARGET" "tokenURI(uint256)" 1 --rpc-url "$RPC"
```

## Examples

```shell
# Deploy the StableLP stack
forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url unichain-sepolia \
  --account three --sender 0x97ba7778dD9CE27bD4953c136F3B3b7b087E14c1 --broadcast --verify

forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url unichain \
  --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify
```


