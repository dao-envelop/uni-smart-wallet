[![CI](https://github.com/dao-envelop/uni-smart-wallet/actions/workflows/test.yml/badge.svg)](https://github.com/dao-envelop/uni-smart-wallet/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity)](https://soliditylang.org)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://getfoundry.sh)
[![Deployed](https://img.shields.io/badge/Deployed-Ethereum%20%C2%B7%20Arbitrum%20%C2%B7%20Base%20%C2%B7%20Unichain-3C3C3D)](#deployments)

# Envelop StableLP

NFT-owned liquidity managers for Uniswap v4. A manager talks to the `PoolManager` directly — no v4
`PositionManager`, no NFT per position — and holds up to 32 configured pools. Control of a manager is a
single ERC-721 token: whoever holds it moves the funds.

## Products

Three implementations share one factory and one base. They differ in which pools they accept and how a
position's range is chosen.

| | Pools | Range | Positions |
|---|---|---|---|
| `StableLPManager` | hookless, configured at init | fixed at `initialize`, per pool | one per pool (`salt == poolId`) |
| `VolatileLPManager` | hookless, configured at init | chosen per call | many per pool, caller-chosen salt |
| `OpenVolatileLPManager` | **any pool, hooked included** | chosen per call | as Volatile |

**`OpenVolatileLPManager` is a research build, not a product for users.** It accepts hooked pools, so
the principal is only as safe as the hook its owner chose; it is deployed on no chain, and the
factory's owner-curated allowlist makes picking it an explicit opt-in.

`StableLPManager` ops: `allocate` (deploy idle balance) · `allocateFrom` (deploy a named just-deposited
token, snapshot-guarded so it cannot dip into pre-existing holdings) · `withdrawTo` · `reinvest` ·
`claimFees`. `VolatileLPManager` adds `recenter` (remove → swap → re-add in one call) and
`moveLiquidity` (the same across two pools).

`moveLiquidity` and the swap guard it shares with the rest live in
[`src/VolatileLPManager.sol`](./src/VolatileLPManager.sol); the operation is covered by
[`test/VolatileLPManagerMove.t.sol`](./test/VolatileLPManagerMove.t.sol), and
[`test/CrossPoolUnlock.t.sol`](./test/CrossPoolUnlock.t.sol) is the manager-free proof that Uniswap v4
permits several pools inside one `unlock` at all. What building it over v4 cost is written down in
[`FEEDBACK.md`](./FEEDBACK.md).

The first two reject hooked pools outright rather than by whitelist — an address says nothing about its
permission bits, and the exit path has no floor to stop a hook with
`AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` skimming principal on the way out.

## Ownership and authorization

The contract holds principal with no admin, no pause switch and no upgrade key. Clones are EIP-1167 and
immutable; a new version means a new implementation, never a migration of yours.

- **The NFT is the authority.** Transferring it hands over the whole manager and clears every operator
  delegation.
- **Operators work, they do not withdraw.** `withdrawTo` and the batch escape hatch are owner-only. An
  operator's position ops are additionally gated by an external `IPriceOracle`, fail-closed: every
  operator swap *and* every operator liquidity add must be vouched for against a Chainlink reference.
  Where the operator also picks the range, the oracle refuses one whose midpoint sits further than
  `maxMidOffsetBps` from that reference — which bounds what a parked range can extract. An operator gets
  one authorized call per transaction. None of this constrains the owner.
- **The fee skim cannot lock your exit.** The 10% protocol fee is taken from realized fees only
  (principal is never taxed) as ERC-6909 claims, not an ERC-20 transfer — so a blocklist or pause on the
  treasury's side can never revert your withdrawal and trap your LP principal.

Honest scope: a token issuer can still freeze its own token at the ERC-20 level. This design adds no
freeze vector of its own and removes the treasury-blocklist lock; it does not override the issuer.

`tokenURI` renders the live portfolio on-chain via `WalletPositionDescriptor`; `UniLens` returns the
whole portfolio, config, operator set and oracle status in one call for frontends.

Design details: [`tasks/spec_StableLPManager.md`](./tasks/spec_StableLPManager.md) ·
asset/delta flow diagrams: [`tasks/StableLPManager_flows_ru.md`](./tasks/StableLPManager_flows_ru.md).

## Deployments

[`deployments/<chainId>.json`](./deployments) is the source of truth; the table below is generated from
it. V4 `PoolManager` addresses come from the
[official Uniswap deployments](https://docs.uniswap.org/contracts/v4/deployments).

| Chain | `LPManagerFactory` | `StableLPManager` | `VolatileLPManager` | `UniLens` | `ChainlinkPriceOracle` | `WalletPositionDescriptor` | `FeeRedeemer` |
|---|---|---|---|---|---|---|---|
| **Ethereum** (1) | [`0x75e5d72D6971221b6332AaE8F59759d4Ba366dd0`](https://etherscan.io/address/0x75e5d72D6971221b6332AaE8F59759d4Ba366dd0) | [`0x4C47Af9CEaFB4571fBed44e97376051f409097e4`](https://etherscan.io/address/0x4C47Af9CEaFB4571fBed44e97376051f409097e4) | [`0xB09216A959cd9444F00cb6aAbd207Bb7b435D223`](https://etherscan.io/address/0xB09216A959cd9444F00cb6aAbd207Bb7b435D223) | [`0xfcb6910d217AAc4B9d7a205473024964A08Bc8eC`](https://etherscan.io/address/0xfcb6910d217AAc4B9d7a205473024964A08Bc8eC) | [`0xa5A1fF40a1F89F26Db124DC56ad6fD8aBb378f29`](https://etherscan.io/address/0xa5A1fF40a1F89F26Db124DC56ad6fD8aBb378f29) | [`0xF4fC2497FaE859Bdb996563140B5a3d4A6D166C3`](https://etherscan.io/address/0xF4fC2497FaE859Bdb996563140B5a3d4A6D166C3) | [`0x3352dbb1507182140225B9aFbeb40e604208F9Fe`](https://etherscan.io/address/0x3352dbb1507182140225B9aFbeb40e604208F9Fe) |
| **Arbitrum One** (42161) | [`0x8A56c6be755aC385395E96234b553DB1B9B06bEa`](https://arbiscan.io/address/0x8A56c6be755aC385395E96234b553DB1B9B06bEa) | [`0xBeBC58DbeE56267dD25e3f1b69E6bdbc84C3eD26`](https://arbiscan.io/address/0xBeBC58DbeE56267dD25e3f1b69E6bdbc84C3eD26) | [`0xFdcBA6be322a293A36eB40f8e01fb572762903E3`](https://arbiscan.io/address/0xFdcBA6be322a293A36eB40f8e01fb572762903E3) | [`0x15E2f43954e7c32044363B19ea64BB290f85bDbE`](https://arbiscan.io/address/0x15E2f43954e7c32044363B19ea64BB290f85bDbE) | [`0x4F59E6454462C9d3851D4B4126DC200FE6209e2D`](https://arbiscan.io/address/0x4F59E6454462C9d3851D4B4126DC200FE6209e2D) | [`0xf17e42fF51c6E1155E4883EBfD34F6C2576E7D41`](https://arbiscan.io/address/0xf17e42fF51c6E1155E4883EBfD34F6C2576E7D41) | [`0x430D09A7969A5c6eF2fb5DcE40972d6e66eF5E33`](https://arbiscan.io/address/0x430D09A7969A5c6eF2fb5DcE40972d6e66eF5E33) |
| **Base** (8453) | [`0x7A3c8F45b809078da58d17fb6Cd059334622838F`](https://basescan.org/address/0x7A3c8F45b809078da58d17fb6Cd059334622838F) | [`0x062858fdA4c60FEcCC662a05291EbED7C900D7E2`](https://basescan.org/address/0x062858fdA4c60FEcCC662a05291EbED7C900D7E2) | [`0x3E861c49E824C06067f9198D8d5F0cB7A2F110d3`](https://basescan.org/address/0x3E861c49E824C06067f9198D8d5F0cB7A2F110d3) | [`0x71B7a17299592e06b80c28C6aB1C1DB5dC67D06D`](https://basescan.org/address/0x71B7a17299592e06b80c28C6aB1C1DB5dC67D06D) | [`0x0A55A8e0Ee3d58e8D7d82803d70092903c593a96`](https://basescan.org/address/0x0A55A8e0Ee3d58e8D7d82803d70092903c593a96) | [`0xa4FA526D8748e88E12FeD13fD951b504f79cB5dE`](https://basescan.org/address/0xa4FA526D8748e88E12FeD13fD951b504f79cB5dE) | [`0x21c23bA0ec49c9440CD259cCB48ff9D06CD16522`](https://basescan.org/address/0x21c23bA0ec49c9440CD259cCB48ff9D06CD16522) |
| **Unichain** (130) | [`0x62D51DFF0c264a5aF8452A10789E4C98b7413A3c`](https://uniscan.xyz/address/0x62D51DFF0c264a5aF8452A10789E4C98b7413A3c) | [`0xB84B23D4B735694c4df802F586E7cBd980263F1c`](https://uniscan.xyz/address/0xB84B23D4B735694c4df802F586E7cBd980263F1c) | [`0xC832b1525Ff272a5Ce30901e0E5f2C71FA47C061`](https://uniscan.xyz/address/0xC832b1525Ff272a5Ce30901e0E5f2C71FA47C061) | [`0xD390620bFa4D7fA7eB1C87303173cD74C3479f96`](https://uniscan.xyz/address/0xD390620bFa4D7fA7eB1C87303173cD74C3479f96) | [`0xfE56c2A6cA650F88D8F5bE6b4F18667C91d259b7`](https://uniscan.xyz/address/0xfE56c2A6cA650F88D8F5bE6b4F18667C91d259b7) | [`0xDC2Dd05BBc708fD5205a2537278290d8e70ba8AE`](https://uniscan.xyz/address/0xDC2Dd05BBc708fD5205a2537278290d8e70ba8AE) | [`0xc73724c684225DB5B1736a510825C0E76E8c9766`](https://uniscan.xyz/address/0xc73724c684225DB5B1736a510825C0E76E8c9766) |
| **Unichain Sepolia** (1301) | [`0xF813Bdc4de2658e2bC7Dd2c4afdeC4846Cfa7986`](https://sepolia.uniscan.xyz/address/0xF813Bdc4de2658e2bC7Dd2c4afdeC4846Cfa7986) | [`0x0aAa44aF7350f25b917B2c9dA60d44D5F28342bf`](https://sepolia.uniscan.xyz/address/0x0aAa44aF7350f25b917B2c9dA60d44D5F28342bf) | [`0x79b90828378AE7d1De22b3bee8b877E4648D459D`](https://sepolia.uniscan.xyz/address/0x79b90828378AE7d1De22b3bee8b877E4648D459D) | [`0xd804c5ccaA9Bf0AcFa635151049e8f785cC0767E`](https://sepolia.uniscan.xyz/address/0xd804c5ccaA9Bf0AcFa635151049e8f785cC0767E) | [`0x36fD134928577f9fF317bF621CBa03Da26716411`](https://sepolia.uniscan.xyz/address/0x36fD134928577f9fF317bF621CBa03Da26716411) | [`0x24F15fC420ff0773F9e949c9cE3474A696e26608`](https://sepolia.uniscan.xyz/address/0x24F15fC420ff0773F9e949c9cE3474A696e26608) | [`0xA6014AAAd7C786b6c502b1F4B017392ac68Fd951`](https://sepolia.uniscan.xyz/address/0xA6014AAAd7C786b6c502b1F4B017392ac68Fd951) |

All rows are release **v2.2.0** (2026-10-21), except the Unichain Sepolia descriptor, which is still
the v2.1.0 one. `OpenVolatileLPManager` is deployed on no chain. Existing managers are clones of
whichever implementation they were created from and keep pointing at it — a redeployed implementation
reaches only managers created after it. The factory allowlists only the v2.2.0 implementations; the
earlier ones are revoked, so no new manager can be cloned from them.

Anyone can create a manager: `LPManagerFactory.createManager(implementation, initData)` clones at a
deterministic CREATE2 address and forwards the product's `initialize` in the same transaction. Since
v2.2.0 `InitParams.oracle` wires the price oracle at birth (the dApp passes the chain's oracle); a clone
created with a zero oracle starts with none, and its operator can do nothing until the owner calls
`setPriceOracle`.

## Build & test

Dependencies are git submodules. Nothing builds until they are initialized.

```bash
git clone --recurse-submodules git@github.com:dao-envelop/uni-smart-wallet.git
cd uni-smart-wallet
# or, in an existing clone:
git submodule update --init --recursive
```

```bash
forge build --sizes      # mirrors CI; the managers must stay under EIP-170 (24,576 B)
forge fmt --check        # CI fails on unformatted files
forge test -vvv          # 407 tests (7 skip); fork tests skip without BASE_RPC
```

CI pins Forge to **1.8.1** — match it locally (`foundryup --install 1.8.1`) before trusting a green run.
1.8 gives each top-level call from a test its own transient storage, as a real transaction does; 1.7
leaked it between them, which changes what the per-transaction operator call limit tests observe.

### Fork tests (live Base)

`test/*.fork.t.sol` run the managers against the production V4 `PoolManager` on Base — native
settle/take/unlock plumbing, gas comparisons, and the operator path behind the real Chainlink feeds.
Env-gated: without `BASE_RPC` they skip, so CI stays green.

```bash
BASE_RPC=https://mainnet.base.org forge test --match-path "test/*.fork.t.sol" -vvv
```

Every `allocate` / `allocateFrom` / `withdrawTo` / `claimFees` / `reinvest` flow was also driven through
the dApp against Unichain mainnet with real value — see the
[UI-mode test report](https://gitlab.com/envelop/protocol-v2/stablelp-ui/-/blob/master/tasks/ui-mode-test-report.en.md).

## Deploy

Per-chain parameters live in [`script/chain_params.json`](./script/chain_params.json), keyed by
`block.chainid`; results are merged into `deployments/<chainId>.json`. The full procedure — including
seeding the oracle with feeds, without which an operator can do nothing — is in
[`script/README.md`](./script/README.md).

```bash
forge script script/DeployStableLP.s.sol --sig "run()" \
  --rpc-url $RPC --account $KEYSTORE --sender $SENDER --broadcast --verify
```

Note that a dry run (the same command without `--broadcast`) also writes `deployments/<chainId>.json`,
with addresses that were never deployed. Revert it before committing.

## Security

Six audit passes live under [`audits/`](./audits):

| Date | Scope |
|---|---|
| [`2026-05-17`](./audits/2026-05-17/AUDIT-REPORT.md) | initial review |
| [`2026-06-23`](./audits/2026-06-23/AUDIT-REPORT.md) | protocol fee |
| [`2026-06-29`](./audits/2026-06-29/AUDIT-REPORT.md) | asset / fee loss |
| [`2026-07-02`](./audits/2026-07-02/AUDIT-REPORT.en.md) | StableLPManager and its dependencies |
| [`2026-07-18`](./audits/2026-07-18/AUDIT-REPORT.en.md) | VolatileLPManager and the post-v1.0.0 refactor |
| [`2026-09-04`](./audits/2026-09-04/AUDIT-REPORT.en.md) | everything changed after `2026-07-18`, plus a [review of the fixes](./audits/2026-09-04/fix-review/FIX-REVIEW.md) |

Two findings shaped the current design: a treasury token blocklist could lock LP principal (fixed by
skimming the fee as ERC-6909 claims), and an operator could drain a bounded slice per operation with no
bound per transaction (fixed by the midpoint rule and the one-call-per-transaction limit).

## License

[MIT](./LICENSE) © 2026 Envelop (dao-envelop).
