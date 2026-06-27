## Deploy log
### Unichain Sepolia
```shell
$ #Deploy Implemenation
$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url unichain-sepolia --account three --sender 0x97ba7778dD9CE27bD4953c136F3B3b7b087E14c1 --broadcast --verify

$ forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url unichain --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify

$ cast send "$TARGET" "setPositionDescriptor(address)" "0xa950991F86eF1b79Db65c4F3893dA9408A1ce157"  --rpc-url unichain --account maxsiz --sender 0xB72993EbB94dc20E4140AFc99A4BC5E42D3d93B2


$ forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url unichain-sepolia --account three --sender 0x97ba7778dD9CE27bD4953c136F3B3b7b087E14c1 --broadcast --verify

$ forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url unichain --account env_deploy_2025 --sender 0x13B9cBcB46aD79878af8c9faa835Bee19B977D3D --broadcast --verify

```
# Deploy scripts

Per-chain parameters live in `chain_params.json`, keyed by `block.chainid`. Deploy
artifacts (addresses) are written to `deployments/<chainId>.json`.

| Script | What it does |
|---|---|
| `DeployWallet.s.sol` | Deploys one `UniSmartWallet`. |
| `DeployStableLP.s.sol` | Deploys the StableLP stack (`FeeRedeemer`, `StableLPManager` impl, `StableLPFactory`, `UniLens`, `WalletPositionDescriptor`) and writes `deployments/<chainId>.json`. |
| `DeployDescriptor.s.sol` | Deploys **only** a `WalletPositionDescriptor` and updates `.descriptor` in `deployments/<chainId>.json`. |
| `CreateManager.s.sol` | Clones one `StableLPManager` via the factory. |

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

`setPositionDescriptor(address)` points a `UniSmartWallet` or `StableLPManager` at a
deployed `WalletPositionDescriptor`, so `tokenURI(1)` renders the position portfolio. It
is `onlyOwnerNFT` (caller must hold the singleton NFT) and is called once after deploy.

The descriptor is deployed once per chain by `DeployStableLP` and shared across every
wallet/manager — its address is in `deployments/<chainId>.json` under `.descriptor`. The
target wallet/manager address is printed at deploy time (`DeployWallet` / `CreateManager`
log it) and is not persisted, so pass it explicitly.

```bash
# TARGET = the UniSmartWallet or StableLPManager (clone) address printed at deploy.
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


