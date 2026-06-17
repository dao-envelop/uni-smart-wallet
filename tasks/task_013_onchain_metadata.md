# Task 013 — On-chain metadata (`tokenURI`) for the wallet's position portfolio

## Goal

The singleton ownership NFT had no on-chain metadata (`UniSmartWallet` never overrode `tokenURI`;
only a dead `DEFAULT_BASE_URI` constant). Render the **portfolio of open positions** on-chain —
per-position principal + uncollected fees — so the NFT reflects live wallet state in marketplaces and
wallets, mirroring Uniswap v4's `PositionManager → IPositionDescriptor` pattern, adapted to a
singleton-portfolio NFT (one token owns N salt-keyed positions, not one NFT per position).

Rendering must live in an **external** contract (EIP-170: the clone-deployed `StableLPManager` is
already tight). Chosen scope: base64 `data:application/json` with per-position attributes + a simple
SVG summary card.

## Changes

### New
- **`src/lib/PositionState.sol`** — view-only valuation `value(pm, owner, salt, position) →
  (amount0, amount1, fees0, fees1)`. Principal via `SqrtPriceMath` (the trimmed v4 `LiquidityAmounts`
  lacks the inverse `getAmountsForLiquidity`); fees via `StateLibrary.getPositionInfo` (last) vs
  `getFeeGrowthInside` (now): `fees = liquidity * ΔfeeGrowthInside / 2**128`. No `unlock`. Split into
  `value` + `_fees` + `_principal` to stay under the stack limit (no via-IR). Degrades to zeros for an
  empty/uninitialized position.
- **`src/interfaces/IWalletDescriptor.sol`** — `tokenURI(address wallet, uint256 tokenId)`.
- **`src/WalletPositionDescriptor.sol`** — shared, deployed-once renderer. Iterates `openSalts`,
  values each position, emits base64 JSON (`name`/`description`/`image` SVG/`attributes`/`positions[]`).

### Wiring (both `UniSmartWallet` and `StableLPManager`)
- `address public positionDescriptor` + `setPositionDescriptor(address)` (owner-only).
- Override `tokenURI(uint256)`: `_requireOwned` then delegate to the descriptor; `address(0)` ⇒ `""`
  (never reverts).
- Emit `IERC4906.MetadataUpdate(TOKEN_ID)` on every position mutation (open/close/decrease/poke;
  allocate/withdrawTo/reinvest/claimFees) and on `setPositionDescriptor`.
- `UniSmartWallet.supportsInterface` now advertises ERC-4906 (`0x49064906`); the stale `TODO` is gone.
- Added a public `poolManager()` view on `V4PositionManager` so the descriptor reads the manager
  generically across both contracts.
- Removed the dead `DEFAULT_BASE_URI` constant.

### Tests
- `test/PositionState.t.sol` — principal both-sided in range, fees zero pre-swap and positive after
  real swaps, unknown salt ⇒ zeros (via a `PositionStateWrapper`).
- `test/WalletPositionDescriptor.t.sol` — `tokenURI` is a valid `data:application/json;base64,` URI
  for empty and populated portfolios; no-descriptor ⇒ `""`; unminted id reverts; setter auth;
  ERC-4906 `MetadataUpdate` on open/close; `supportsInterface(0x49064906)`.

## Result

`StableLPManager` runtime ~23,380 bytes (still under EIP-170, margin ~1,196). `WalletPositionDescriptor`
is a separate ~7.8 KB contract. All tests green (101 pass, 1 fork skipped without `BASE_RPC`).

## Verification

- `forge build --sizes` — wallets under EIP-170.
- `forge fmt --check`.
- `forge test --match-path test/PositionState.t.sol -vvv`
- `forge test --match-path test/WalletPositionDescriptor.t.sol -vvv`
- `forge test` — 101 pass / 1 skipped.
