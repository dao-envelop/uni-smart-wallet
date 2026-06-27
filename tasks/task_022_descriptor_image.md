# Task 022 — Redesign the WalletPositionDescriptor NFT image

## Goal

The shared on-chain `tokenURI` renderer (`src/WalletPositionDescriptor.sol`) currently draws a
static 320×180 card with a hardcoded `Envelop UniSmartWallet` title and only the open-position
count. Make the `image` carry real portfolio data and the right product name:

- Envelop logo as background watermark.
- Header = the NFT `name()` (so `UniSmartWallet` and `StableLPManager` each label themselves).
- Open-position count.
- Total value (USD).
- Stablecoin icons.
- Approximate APR (`~APR`).

## Decisions

- **Total value**: `1 stable = $1`; normalize each token amount by its on-chain `decimals()`
  (read via staticcall, fallback 18). No price oracle.
- **Icons**: brand-colored coin + ticker for known stables (USDC `#2775CA`, USDT `#26A17B`,
  DAI `#F5AC37`), neutral fallback coin otherwise. Ticker from `symbol()` (staticcall).
- **APR**: approximate, labeled `~APR`. `Σ(feeUsd_i · year / elapsed_i) / Σ principalUsd_i`,
  using `Position.openedAt`. Understated after a `poke`/`reinvest` (fee growth resets, `openedAt`
  doesn't) — documented in NatSpec.
- **Scope**: one design for both products; header from `name()`. Fix `UniSmartWallet`'s
  placeholder ERC721 name (`"ERC721 Name"` → `"Envelop UniSmartWallet"`).

## Changes

- `src/UniSmartWallet.sol`: ctor `ERC721("Envelop UniSmartWallet", "eUSW")`.
- `src/lib/DescriptorLib.sol` (new): inlined Envelop logo, `tokenIcon`, `formatUsd`,
  `formatPercentBps`.
- `src/WalletPositionDescriptor.sol`: name from `name()`; aggregate total value / APR / distinct
  currencies; new `_svg`; add JSON attributes `Total Value (USD)`, `Est. APR (bps)`.
- Tests: `test/WalletPositionDescriptor.t.sol` (+ a `DescriptorLib` wrapper under `test/helpers/`).

## Notes

- Descriptor is a standalone deployment — embedding the ~6 KB logo does **not** touch the
  EIP-170-tight `StableLPManager` clone (see task 021). Still run `forge build --sizes`.
- The descriptor's `name` for the manager today is the `pure` constant `"Envelop StableLP"`
  (task 021's per-clone name is backlog, not yet implemented).
