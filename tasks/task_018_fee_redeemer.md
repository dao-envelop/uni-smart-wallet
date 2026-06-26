# Task 018 — FeeRedeemer (ERC-6909 protocol-fee cash-out)

## Goal
The `StableLPManager` protocol fee accrues as ERC-6909 **claims** inside the PoolManager to
`PROTOCOL_TREASURY` (a `mint`, deliberately not an ERC-20 transfer, so a stablecoin blocklist/pause on
the treasury can't revert the LP exit path). An EOA treasury can't turn those claims into real tokens —
that needs `unlock → burn → take`. FeeRedeemer is the contract that does it.

## What was built
`src/FeeRedeemer.sol` — `IUnlockCallback`, owner-gated (OZ `Ownable`). Intended to **be** the treasury.
- `claimable(currency)` → this contract's ERC-6909 claim balance (`balanceOf(this, currency.toId())`).
- `redeem(Currency[] currencies, address to)` (onlyOwner) → `unlock`; in the callback, per currency:
  `burn(address(this), id, bal)` (credits +bal delta) then `take(currency, to, bal)` (ERC-20/native out,
  nets to 0). No `settle` — the burn already creates the credit. Native (`Currency(0)`) handled by `take`.
- `burn(address(this), …)` needs no ERC-6909 approval because the claims accrue here (redeemer == treasury).
- Caller supplies the currency list (= the manager's `managedStables`); the PoolManager can't enumerate
  a holder's claims on-chain. Skips zero balances.

## Deploy ordering (decided: redeemer == treasury)
`PROTOCOL_TREASURY` is immutable on the `StableLPManager` implementation, so:
1. Deploy `FeeRedeemer(poolManager, protocolOwner)`.
2. Deploy the `StableLPManager` implementation with `treasury_ = address(feeRedeemer)`.
3. Deploy `StableLPFactory(impl)`; clones inherit that treasury.

No StableLP deploy script exists yet (`script/` only has `DeployWallet.s.sol`); when one is added, wire
this ordering there.

## Tests (`test/FeeRedeemer.t.sol`)
- ERC-20: a manager with `treasury = redeemer` allocates, real swaps accrue fees, `claimFees` skims
  ERC-6909 to the redeemer; `claimable() > 0`; owner `redeem([c0,c1], payout)` pays the exact claim to
  `payout` and zeroes the claim; non-owner `redeem` reverts (`OwnableUnauthorizedAccount`); foreign
  `unlockCallback` reverts (`NotPoolManager`).
- Native: ETH-pool fee accrues as ERC-6909 id 0; `redeem([NATIVE], recipient)` delivers ETH and clears
  the claim.

## Future
Tokenization spike (`tasks/spec_StableLPVault_spike.md`) is the related larger design (ERC-7575 wrapper);
not built here.
