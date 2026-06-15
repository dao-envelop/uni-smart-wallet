# Task 009 — Extract singleton-NFT auth base (`SingletonNFTOwned`)

## Goal

The upcoming `StableLPManager` reuses `UniSmartWallet`'s singleton-NFT + operator authorization "verbatim" (per `tasks/spec_StableLPManager.md`). To avoid duplicating this security-critical code, extract it into a shared abstract base that both `UniSmartWallet` and `StableLPManager` inherit.

This is the enabling step before `StableLPManager` (task 010).

## Scope

1. New `src/abstract/SingletonNFTOwned.sol` (`abstract contract is ERC721`): `TOKEN_ID`, `_singletonMinted`, `operators`/`_operatorList`, `onlyOwnerNFT`/`onlyAuthorized`, `setOperator`, `_update` (singleton invariant + operator auto-clear), `_clearOperators`, `ownerNFTHolder`, auth errors/events. The mint is performed by the subclass via `_mintSingleton(to)` (constructor for the wallet, `initialize` for the clone).
2. Refactor `UniSmartWallet` to `is SingletonNFTOwned, SmartWallet, V4PositionManager`; behavior identical.
3. Re-qualify moved auth errors in tests to `SingletonNFTOwned.*` + add import (inherited errors aren't reachable via the derived contract name).

## Out of scope

`StableLPManager` / `StableLPFactory` (task 010).

## Verification

- `forge build --sizes`, `forge fmt --check`.
- Full existing suite stays green: `forge test --no-match-path test/UniSmartWallet.fork.t.sol` (80 tests).
- Fork suite compiles + skips without `BASE_RPC`.
