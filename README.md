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
- **On-chain `tokenURI`** — the singleton NFT renders the live position portfolio (`WalletPositionDescriptor`),
  with a read aggregator (`UniLens`) for frontends.
- **EIP-1167 clones** via `StableLPFactory` (atomic clone + `initialize`); per-clone NFT name with a
  default fallback of `Envelop LP Uniswap Manager`.

Design details: [`tasks/spec_StableLPManager.md`](./tasks/spec_StableLPManager.md) ·
asset/delta flow diagrams: [`tasks/StableLPManager_flows_ru.md`](./tasks/StableLPManager_flows_ru.md).

## Deployments

Addresses are the source of truth in [`deployments/<chainId>.json`](./deployments). V4 `PoolManager`
addresses come from the [official Uniswap deployments](https://docs.uniswap.org/contracts/v4/deployments).

| Chain | `StableLPFactory` | `StableLPManager` (impl) | `FeeRedeemer` | `UniLens` | `WalletPositionDescriptor` |
|---|---|---|---|---|---|
| **Ethereum** (1) | `0x17b2B071821E1c3DF2C325E7c53B9D907a8436bE` | `0xe4c62017a9044CE0Bf6519A02626224d9D3aB471` | `0x3352dbb1507182140225B9aFbeb40e604208F9Fe` | `0xb309F1f386AaaBe8f1Dc81Fc2226DCe2B23de214` | `0x3218aa613C3545cf5Bf1698155e7BBb924A9b791` |
| **Arbitrum One** (42161) | `0xAE46573C559d2ef665102E86289685C2602D96e3` | `0x6Cd8a96c9A6E441Bfeea521F1B8E4b757debbD04` | `0x430D09A7969A5c6eF2fb5DcE40972d6e66eF5E33` | `0x498E0Bb7F7413272D1cFa3B1219e13598498d428` | `0x7D85544213E61595f8757EBE0D0bF903bafb789d` |
| **Base** (8453) | `0x653bce4d7A6CF5C4FdbBD5fc6B2bB41c8eAFC56A` | `0xa98F88B8Fb494651a7F5cAff67E86E94AD7b424a` | `0x21c23bA0ec49c9440CD259cCB48ff9D06CD16522` | `0x4F85fFB544c0DE49a231408157c5b8dAB4A55a1C` | `0x22bBBE241464AB67c9B4F0881fA45F7f2d26870F` |
| **Unichain** (130) | `0xC425A68df03764F648883b961eb982f087fe22ca` | `0x886D60f9218A53546A4046BDf66c28881e67aD96` | `0xc73724c684225DB5B1736a510825C0E76E8c9766` | `0x4765B0E28cdC0a9fd715B3520e94870473D3e7e4` | `0xDAf75f915e648FBdE1017733B3E8998bBD29f0ba` |
| **Unichain Sepolia** (1301) | `0x63c6c2D5cC5E987e59D321a4e4e9560c346fb8e8` | `0x746D334045E3F755984d111340cC158e7D89864e` | `0xA6014AAAd7C786b6c502b1F4B017392ac68Fd951` | `0xFaF8815D478cf2d8dbCE81440551e99Ce9fB1D52` | `0xDfEEB1e46C110Bea6d299136556003054c5C8363` |

A new manager is created by anyone via `StableLPFactory.createManager(InitParams)`; the singleton NFT is
minted to the configured owner.

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

The StableLP suites boot a `StableLPFactory` with a multi-pool stable config (`test/helpers/StableLPTestBase.sol`):

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
