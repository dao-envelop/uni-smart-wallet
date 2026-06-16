# Task 011 — Shrink StableLPManager under the EIP-170 size limit

## Goal

`StableLPManager` (task 010) was ~28.9 KB runtime — over the 24,576-byte EIP-170 limit, so it
couldn't deploy to mainnet/L2 as a single contract. Reduce the contract's own bytecode (without the
heavier delegatecall split) so it deploys with healthy margin, keeping all 98 tests green.

`via_ir` can't be enabled (v4-core `PoolManager` hits Yul stack-too-deep) and optimizer-runs save
<0.5 KB, so the reduction is structural — removing code the contract doesn't need.

## Changes (only `src/StableLPManager.sol`, + one-word base tweak)

- **Drop `SmartWallet` inheritance** → `is SingletonNFTOwned, V4PositionManager`. The manager is
  ERC20-only custody: keeps a minimal `receive()` for native, drops `ERC721Holder`/`ERC1155Holder`
  (no NFT/1155 receive) and the now-unneeded `supportsInterface` override (ERC721's default suffices).
- **Batch-only owner calls**: replace the inherited `executeEncodedTx`/`executeEncodedTxBatch` with a
  single inlined `executeEncodedTxBatch` over OZ `Address` (a 1-element batch covers single calls).
- **Strip unused base handlers**: override `unlockCallback` to dispatch only the ops this product
  uses (POKE, ALLOCATE, WITHDRAW_TO, REINVEST), making the base's OPEN/CLOSE/DECREASE handlers
  unreachable so the compiler strips them. Requires marking the base `unlockCallback` `virtual`
  (`src/abstract/V4PositionManager.sol`) — the only base change.
- **Dedupe**: extract the shared size-add-cap-record sequence of allocate/reinvest into one
  `_addLiquidity` helper; compact `_pairSide(Currency,Currency)` (no PoolKey struct copies).

## API surface trimmed (deviation from task 010 / spec — for review)

Removed from `StableLPManager` (still present in `UniSmartWallet`):
- `executeEncodedTx` (single) — use `executeEncodedTxBatch` with one element.
- `decreasePosition`, `pokePosition` — `claimFees(salt)` still harvests fees (it is the poke path);
  partial unwind-to-manager (`decreasePosition`) is gone. Re-adding it needs ~0.9 KB of the margin
  or a delegatecall split.
- `setPoolConfig` — pool config is now effectively immutable post-`initialize` (also avoids
  orphaning positions under stale salts).
- NFT/ERC1155 receive (`ERC721Holder`/`ERC1155Holder`): `safeTransfer` of an NFT to the manager
  reverts; plain ERC20 transfers and owner-driven calls via `executeEncodedTxBatch` are unaffected.

## Result

`StableLPManager` runtime ~23,696 bytes — under 24,576 (margin ~ +880). `UniSmartWallet`, the bases
(except the `virtual` keyword), and the factory are otherwise unchanged.

## Verification

- `forge build --sizes` — `StableLPManager` under limit (positive margin).
- `forge fmt --check`.
- `forge test --no-match-path "test/*.fork.t.sol"` — 98 pass (incl. the withdraw
  manager-balance-unchanged invariant, allocate netting, reinvest/claimFees).
- Fork suites compile + skip without `BASE_RPC`.
