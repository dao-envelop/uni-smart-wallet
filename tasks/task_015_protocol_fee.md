# Task 015 — Protocol fee (10%) on realized fees in StableLPManager

## Goal

Give the protocol revenue: skim a constant **10% (1000 bps)** of every **realized fee accrual** in
`StableLPManager` to an immutable protocol treasury. Must be **unavoidable** — not bypassable via
`reinvest` / `withdrawTo` / `allocate` top-ups.

## Design

V4's `modifyLiquidity` returns `feesAccrued` as its second value. The fee is enforced by a single
rule: **at every `modifyLiquidity` that realizes fees, skim `feesAccrued * 10%` to the treasury** via
the v4-native `take` (inside the active unlock — no extra ERC-20 transfer). This covers all paths:

- `claimFees` (poke, `modifyLiquidity(0)`),
- `reinvest` (realize `modifyLiquidity(0)`, skimmed before compounding),
- `withdrawTo` (`_pullLiquidity`, `modifyLiquidity(-L)` — only the fee component, principal untouched),
- `allocate` top-up of an existing position (`_addLiquidity`, `modifyLiquidity(+L)`; a fresh position
  has `feesAccrued == 0`, so principal deposits are never taxed).

Treasury is **`immutable`**, set by the protocol at implementation deploy and shared by all clones —
deliberately **not** owner-settable, or the owner would redirect the fee to themselves and zero it out.
The percentage is a `constant`.

## Changes — `src/StableLPManager.sol`

- `uint16 public constant PROTOCOL_FEE_BPS = 1000;`, `address public immutable PROTOCOL_TREASURY;`,
  `error ZeroTreasury;`, `event ProtocolFeeTaken(Currency indexed currency, uint256 amount)`.
- Constructor takes `(IPoolManager, address treasury_)`; reverts `ZeroTreasury` on a zero treasury.
- Helpers `_skimFees(PoolKey, BalanceDelta feesAccrued)` / `_skimFee(Currency, int128)` / `_pos(int128)`.
- Skim sites: `_addLiquidity`, `_handleReinvest` (realize), `_pullLiquidity`, and a new `_handleClaim`
  that replaces the base `_handlePoke` for the POKE op (so the base poke/close/decrease/withdraw
  handlers become unreachable and the compiler strips them — partially offsetting the new code).

`StableLPFactory` unchanged (clones an implementation already wired with the treasury).

## Tests

- `StableLPTestBase`: `treasury = address(0xFEE5)`; impl deployed with it. `StableLPManagerV2`
  7-pool test passes a treasury too.
- New `test/StableLPManagerProtocolFee.t.sol`: `claimFees` skims exactly 10% (asserts manager == 9×
  treasury), `reinvest` and `withdrawTo` credit the treasury, and a zero-treasury constructor reverts.
- Existing suites unaffected (they used `assertGt`/`assertGe`, not exact fee amounts).

## Result

`StableLPManager` runtime ~23,991 bytes (margin ~585, under EIP-170 — feature added ~236 B net). All
tests pass: 115, 1 fork skipped without `BASE_RPC`.

## Verification

```bash
forge fmt --check
forge build --sizes        # StableLPManager under 24,576
forge test --match-path "test/StableLPManagerProtocolFee.t.sol" -vvv
forge test                 # full regression (115 pass / 1 skipped)
```
