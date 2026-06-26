# Deploy scripts

Per-chain parameters live in `chain_params.json`, keyed by `block.chainid`. Deploy
artifacts (addresses) are written to `deployments/<chainId>.json`.

| Script | What it does |
|---|---|
| `DeployWallet.s.sol` | Deploys one `UniSmartWallet`. |
| `DeployStableLP.s.sol` | Deploys the StableLP stack (`FeeRedeemer`, `StableLPManager` impl, `StableLPFactory`, `UniLens`, `WalletPositionDescriptor`) and writes `deployments/<chainId>.json`. |
| `CreateManager.s.sol` | Clones one `StableLPManager` via the factory. |

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
