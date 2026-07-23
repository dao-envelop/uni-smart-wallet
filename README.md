[![CI](https://github.com/dao-envelop/uni-smart-wallet/actions/workflows/test.yml/badge.svg)](https://github.com/dao-envelop/uni-smart-wallet/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity)](https://soliditylang.org)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://getfoundry.sh)
[![Deployed](https://img.shields.io/badge/Deployed-Ethereum%20%C2%B7%20Arbitrum%20%C2%B7%20Base%20%C2%B7%20Unichain-3C3C3D)](#deployments)

# Envelop StableLP

> **Park your stablecoins as Uniswap v4 liquidity, earn the trading fees — non-custodial and unfreezable.**

**StableLPManager** is an NFT-owned, factory-cloned manager that provides liquidity into a configured
set of stable pools on Uniswap v4. Deposit any managed stablecoin, let an operator spread it across the
pools, and earn the swap fees. Withdraw at any time straight to any address — the requested stable is
delivered via the v4-native `take`, so it never lands on the manager's or your balance first.

## Why "unfreezable"

The contract holds your principal with **no admin, no pause switch, and no upgrade key**:

- **You are the only authority.** Control of a manager is a single, non-burnable ERC-721 NFT — whoever
  holds it moves the funds. Transferring the NFT atomically hands over the whole manager (and clears any
  operator delegations).
- **Operators can work, not withdraw.** You can delegate position management to a bot (`allocate` /
  `reinvest` / `claimFees`), but the drain primitives (`withdrawTo`, the batch escape hatch) are
  owner-only.
- **The fee skim can't lock your exit.** The 10% protocol fee is taken as **ERC-6909 claims**, not an
  ERC-20 transfer, so a stablecoin blocklist/pause on the protocol treasury can never revert your
  withdrawal and trap your LP principal.

> Caveat — honest scope: a stablecoin issuer can still freeze *its own* token at the ERC-20 level. This
> design adds no freeze vector of its own and specifically removes the treasury-blocklist lock; it does
> not (and cannot) override the issuer's controls on the underlying token.

## Features

- **Multi-pool stable LP** over arbitrary pairs (including native-ETH pools), keyed `salt == poolId`
  (one position per pool).
- **Operations:** `allocate` (auto-deploy idle balance) · `allocateFrom` (deploy a named just-deposited
  stable, snapshot-guarded so it can't dip into pre-existing holdings) · `withdrawTo` (indirect drain via
  v4 `take`) · `reinvest` (compound fees) · `claimFees` (harvest).
- **Hookless-only pools** — pools with hooks are categorically rejected (the most security-load-bearing
  gate; it's what makes operator delegation safe).
- **10% protocol fee** skimmed from realized fees only (principal is never taxed), as ERC-6909 claims to
  an immutable treasury; redeemed via `FeeRedeemer`.
- **On-chain `tokenURI`** — the singleton NFT renders the live position portfolio (`WalletPositionDescriptor`,
  which values a position at the live pool price with the stable leg anchored at $1), with a read aggregator
  (`UniLens`) for frontends.
- **Volatile pairs** — `VolatileLPManager` handles arbitrary/volatile pairs: many positions per pool at
  per-call ranges, `recenter` (remove → swap → re-add in one call), and an `IPriceOracle` guard that gates
  operator swaps fail-closed (owner swaps bypass).
- **EIP-1167 clones** via the universal `LPManagerFactory` (atomic clone + `initialize`; allowlists both
  the Stable and Volatile implementations); per-clone NFT name with a default fallback of
  `Envelop LP Uniswap Manager`.

Design details: [`tasks/spec_StableLPManager.md`](./tasks/spec_StableLPManager.md) ·
asset/delta flow diagrams: [`tasks/StableLPManager_flows_ru.md`](./tasks/StableLPManager_flows_ru.md).

## Deployments

Addresses are the source of truth in [`deployments/<chainId>.json`](./deployments). V4 `PoolManager`
addresses come from the [official Uniswap deployments](https://docs.uniswap.org/contracts/v4/deployments).

Columns: universal `LPManagerFactory`, the `StableLPManager` and `VolatileLPManager` implementations,
`FeeRedeemer`, `UniLens`, `WalletPositionDescriptor`, and `ChainlinkPriceOracle`.

| Chain | `LPManagerFactory` | `StableLPManager` (impl) | `VolatileLPManager` (impl) | `FeeRedeemer` | `UniLens` | `WalletPositionDescriptor` | `ChainlinkPriceOracle` |
|---|---|---|---|---|---|---|---|
| **Ethereum** (1) | [`0x75e5d72D6971221b6332AaE8F59759d4Ba366dd0`](https://blockscan.com/address/0x75e5d72D6971221b6332AaE8F59759d4Ba366dd0) | [`0x5a4417E55880De60A5b8C25F2100e7ba42BC43Bb`](https://blockscan.com/address/0x5a4417E55880De60A5b8C25F2100e7ba42BC43Bb) | [`0x16932D018Da2F84ce4a784Fac71Fb0924F389F92`](https://blockscan.com/address/0x16932D018Da2F84ce4a784Fac71Fb0924F389F92) | [`0x3352dbb1507182140225B9aFbeb40e604208F9Fe`](https://blockscan.com/address/0x3352dbb1507182140225B9aFbeb40e604208F9Fe) | [`0xC0dB1c4f28bF5956871aA217f87F73023ebc6cd9`](https://blockscan.com/address/0xC0dB1c4f28bF5956871aA217f87F73023ebc6cd9) | [`0x67a2CD3804F2e5E7e09cA213929011A77C8aefEa`](https://blockscan.com/address/0x67a2CD3804F2e5E7e09cA213929011A77C8aefEa) | [`0x67b914B41967AbFF6231E9c5114eA7Bc533Dfc9B`](https://blockscan.com/address/0x67b914B41967AbFF6231E9c5114eA7Bc533Dfc9B) |
| **Arbitrum One** (42161) | [`0x8A56c6be755aC385395E96234b553DB1B9B06bEa`](https://blockscan.com/address/0x8A56c6be755aC385395E96234b553DB1B9B06bEa) | [`0x7f373092bDAFdc47a34c406Ec7Ac903B7780C4a2`](https://blockscan.com/address/0x7f373092bDAFdc47a34c406Ec7Ac903B7780C4a2) | [`0xa373FBAcd0964FCb7BC01CB447a2F25f11E8995b`](https://blockscan.com/address/0xa373FBAcd0964FCb7BC01CB447a2F25f11E8995b) | [`0x430D09A7969A5c6eF2fb5DcE40972d6e66eF5E33`](https://blockscan.com/address/0x430D09A7969A5c6eF2fb5DcE40972d6e66eF5E33) | [`0x205549BCb010D429354aabc2CaE057B090BcF5B8`](https://blockscan.com/address/0x205549BCb010D429354aabc2CaE057B090BcF5B8) | [`0x330ce9c5d9271b0aeC08cD363C535Ef126743b0c`](https://blockscan.com/address/0x330ce9c5d9271b0aeC08cD363C535Ef126743b0c) | [`0xf8dA8DC6d8cDCadcc96b51d5fC0Cb59EF3672005`](https://blockscan.com/address/0xf8dA8DC6d8cDCadcc96b51d5fC0Cb59EF3672005) |
| **Base** (8453) | [`0x7A3c8F45b809078da58d17fb6Cd059334622838F`](https://blockscan.com/address/0x7A3c8F45b809078da58d17fb6Cd059334622838F) | [`0x9C10eD902Ae7fD997D92eeD7535849f204b727b7`](https://blockscan.com/address/0x9C10eD902Ae7fD997D92eeD7535849f204b727b7) | [`0x28466e3e92CB6FB292618D0faEbB49624f4d6f0C`](https://blockscan.com/address/0x28466e3e92CB6FB292618D0faEbB49624f4d6f0C) | [`0x21c23bA0ec49c9440CD259cCB48ff9D06CD16522`](https://blockscan.com/address/0x21c23bA0ec49c9440CD259cCB48ff9D06CD16522) | [`0x54B328Ef3A93b4a22896187588166fF361Ea0f1E`](https://blockscan.com/address/0x54B328Ef3A93b4a22896187588166fF361Ea0f1E) | [`0xa950991F86eF1b79Db65c4F3893dA9408A1ce157`](https://blockscan.com/address/0xa950991F86eF1b79Db65c4F3893dA9408A1ce157) | [`0xf58208676a7b5a604df41ca25b5310f3cc997bF3`](https://blockscan.com/address/0xf58208676a7b5a604df41ca25b5310f3cc997bF3) |
| **Unichain** (130) | [`0x62D51DFF0c264a5aF8452A10789E4C98b7413A3c`](https://blockscan.com/address/0x62D51DFF0c264a5aF8452A10789E4C98b7413A3c) | [`0x71B7a17299592e06b80c28C6aB1C1DB5dC67D06D`](https://blockscan.com/address/0x71B7a17299592e06b80c28C6aB1C1DB5dC67D06D) | [`0x0A55A8e0Ee3d58e8D7d82803d70092903c593a96`](https://blockscan.com/address/0x0A55A8e0Ee3d58e8D7d82803d70092903c593a96) | [`0xc73724c684225DB5B1736a510825C0E76E8c9766`](https://blockscan.com/address/0xc73724c684225DB5B1736a510825C0E76E8c9766) | [`0x03Ed05c589B567D94d2dc0157A8D8DC365f82bc7`](https://blockscan.com/address/0x03Ed05c589B567D94d2dc0157A8D8DC365f82bc7) | [`0x5406073Cd50d338fb80A850aAa78b8401eD6D82e`](https://blockscan.com/address/0x5406073Cd50d338fb80A850aAa78b8401eD6D82e) | [`0xAC7966454B32006de29273094Ff0FCf8D367eF87`](https://blockscan.com/address/0xAC7966454B32006de29273094Ff0FCf8D367eF87) |
| **Unichain Sepolia** (1301) | [`0xF813Bdc4de2658e2bC7Dd2c4afdeC4846Cfa7986`](https://blockscan.com/address/0xF813Bdc4de2658e2bC7Dd2c4afdeC4846Cfa7986) | [`0x789B70962c78c703Ec3403a722921Ecf1c823684`](https://blockscan.com/address/0x789B70962c78c703Ec3403a722921Ecf1c823684) | [`0x31D497F619DB989268c346D11fd7D980052124E1`](https://blockscan.com/address/0x31D497F619DB989268c346D11fd7D980052124E1) | [`0xA6014AAAd7C786b6c502b1F4B017392ac68Fd951`](https://blockscan.com/address/0xA6014AAAd7C786b6c502b1F4B017392ac68Fd951) | [`0x7CDCBEa338ce3598F8caEFa6A3883f72395b9E3e`](https://blockscan.com/address/0x7CDCBEa338ce3598F8caEFa6A3883f72395b9E3e) | [`0x24F15fC420ff0773F9e949c9cE3474A696e26608`](https://blockscan.com/address/0x24F15fC420ff0773F9e949c9cE3474A696e26608) | [`0xaA8D8504c86619bc39a81cce0E35d1d2e164dB51`](https://blockscan.com/address/0xaA8D8504c86619bc39a81cce0E35d1d2e164dB51) |

A new manager is created by anyone via `LPManagerFactory.createManager(implementation, InitParams)`; the
singleton NFT is minted to the configured owner.

## Build & test

Solidity dependencies are vendored as git submodules under `lib/`. Nothing builds until they are
initialized.

```bash
# Fresh clone
git clone --recurse-submodules git@github.com:dao-envelop/uni-smart-wallet.git
cd uni-smart-wallet

# Existing clone / after switching branches
git submodule update --init --recursive
```

```bash
forge build --sizes      # mirrors CI
forge fmt --check        # CI fails on unformatted files
forge test -vvv          # full suite (fork tests skip without BASE_RPC)
```

The StableLP suites boot an `LPManagerFactory` with a multi-pool stable config (`test/helpers/StableLPTestBase.sol`):

```bash
forge test --match-path "test/StableLP*.t.sol" -vvv          # factory, allocate/withdraw, protocol fee, native, audit fixes
forge test --match-path test/StableLPManagerAllocate.t.sol -vvv
forge test --match-path test/StableLPManagerWithdraw.t.sol -vvv
```

### Fork test (live Base V4 PoolManager)

`test/StableLPManager.fork.t.sol` exercises a **non-stable pool (native ETH + USDC)** against the
production V4 `PoolManager` on Base — verifying the native settle/take/unlock plumbing against the real
contract. It is **env-gated**: without `BASE_RPC` it skips cleanly, so `forge test` stays green in CI.

```bash
BASE_RPC=https://mainnet.base.org \
  forge test --match-path test/StableLPManager.fork.t.sol -vvv
```

### Live on-chain verification (Unichain mainnet)

Every `allocate` / `allocateFrom` / `withdrawTo` / `claimFees` / `reinvest` flow was driven through the
dApp against **Unichain mainnet** with real transactions and value preserved end-to-end — see the
[UI-mode test report](https://gitlab.com/envelop/protocol-v2/stablelp-ui/-/blob/master/tasks/ui-mode-test-report.en.md).

## Deploy

Per-chain parameters live in [`script/chain_params.json`](./script/chain_params.json) (keyed by
`block.chainid`); deploy artifacts are written to `deployments/<chainId>.json`. The full deploy +
descriptor-wiring guide is in [`script/README.md`](./script/README.md).

```bash
forge script script/DeployStableLP.s.sol --sig "run()" \
  --rpc-url $RPC --account $KEYSTORE --sender $SENDER --broadcast --verify
```

## Security

Three independent audit passes live under [`audits/`](./audits): the initial review
([`2026-05-17`](./audits/2026-05-17/AUDIT-REPORT.md)), the protocol-fee review
([`2026-06-23`](./audits/2026-06-23/AUDIT-REPORT.md)), and an asset/fee-loss-focused review
([`2026-06-29`](./audits/2026-06-29/AUDIT-REPORT.md)). The headline HIGH (a treasury token blocklist
locking LP principal) is fixed by skimming the protocol fee as ERC-6909 claims.

## License

[MIT](./LICENSE) © 2026 Envelop (dao-envelop).
