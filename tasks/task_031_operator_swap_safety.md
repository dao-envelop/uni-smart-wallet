# Task 031 — Operator swap safety (audit H-VOL-1 / M-VOL-2, VolatileLPManager)

Follow-up to the `audits/2026-07-18` audit. Closes **H-VOL-1** (a compromised operator drains a
position's principal via `recenter`'s operator-parameterized swap) and its root **M-VOL-2** (no mandatory
non-operator swap-slippage floor; oracle off-by-default & fail-open) — **for `VolatileLPManager` only**
(Stable is EIP-170-tight and handled separately).

## Design (chosen with the user): owner/operator-asymmetric swap guard

- The **NFT owner keeps full freedom**: owner-triggered swaps are unrestricted.
- An **operator** keeps every method, but any operator-triggered **swap** (`swapAmountIn > 0`) must be
  vouched for by a trusted, **actually-enforcing** price oracle. An operator cannot self-authorize an
  adverse (sandwichable) swap.
- Swapless operator ops (`allocate`/`recenter` with `swapAmountIn == 0`) stay unrestricted — L is sized
  from desired amounts, so owed ≤ desired and there is no value-loss vector.

## Code changes (`src/`)

1. **`interfaces/IPriceOracle.sol`** — `check(...)` now **returns `bool enforced`**: `true` when it checked
   against a fresh reference (reverting on out-of-bounds), `false` when it had no fresh reference. This
   lets the caller distinguish "in bounds" from "no opinion" and closes the fail-open hole.
2. **`VolatileLPManager.sol`**
   - Thread `bool byOwner = ownerOf(TOKEN_ID) == msg.sender` (computed at the external entry) into the
     `OP_ALLOCATE_V` / `OP_RECENTER` unlock payloads.
   - `_guardSwap(byOwner, key, zeroForOne, amountIn, amountOut)`: owner ⇒ return; operator ⇒ require
     `priceOracle != 0` (`OperatorSwapGuardRequired`) and `check(...) == true`
     (`OperatorSwapUnverified`) — **fail-closed** for operators.
   - New errors `OperatorSwapGuardRequired` / `OperatorSwapUnverified(PoolId)`.
3. **`oracle/ChainlinkPriceOracle.sol`** — reference `IPriceOracle` implementation over Chainlink USD
   feeds (per-currency feed + heartbeat + token decimals, `maxDeviationBps` tolerance). Returns `false`
   on a missing/stale reference; reverts `PriceOutOfBounds` when the realized price deviates too far.

## Tests
- `test/helpers/Mocks.sol` — `MockPriceOracle` (NotEnforced / Pass / Revert modes).
- `test/VolatileLPManagerOperatorSwapGuard.t.sol` — operator recenter/allocate swap: reverts without an
  oracle, reverts on a non-enforcing oracle, reverts on an out-of-bounds oracle, succeeds on an in-bounds
  oracle; **owner bypasses** (swap succeeds with no oracle); swapless operator ops unaffected. Includes a
  value-extraction PoC showing the operator drain now reverts while the owner path still executes.
- `test/ChainlinkPriceOracle.t.sol` — reference-oracle behaviour against a mock aggregator.

## Verification
```bash
forge fmt --check
forge build --sizes            # VolatileLPManager < 24576 B
forge test -vvv
```
</content>
