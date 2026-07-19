# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Operator swap safety** — audit `2026-07-18` H-VOL-1 / M-VOL-2 (task_031 + task_032). Any
  **operator-triggered** swap in either product — `VolatileLPManager` (allocate pre-swap / recenter
  rebalance) and `StableLPManager` (allocate pre-swap / reinvest swap) — is now gated by the
  `priceOracle` and **fail-closed**: it reverts unless a configured oracle vouches for the realized price
  (`OperatorSwapGuardRequired` when unset, `OperatorSwapUnverified` when the oracle has no fresh
  reference). This closes the drain where a compromised operator freed a position's principal via
  `VolatileLPManager.recenter` and routed it through a self-parameterized adverse swap, and the
  idle+fees bleed via the Stable pre-swaps. The **NFT owner keeps full freedom** (owner swaps bypass the
  guard). The guard (`priceOracle` / `setPriceOracle` / `_guardSwap`) lives in `BaseLPManager`, shared by
  both products. `IPriceOracle.check` now returns `bool enforced` (closing the prior fail-open); added
  `src/oracle/ChainlinkPriceOracle.sol` reference implementation.
- **Factory clone-address binding (`LPManagerFactory`)** — audit `2026-07-18` L-FAC-1 (task_033). The
  CREATE2 salt now binds `keccak256(initData)`, so a front-runner can no longer deploy a different pool
  config at a caller's predicted, pre-funded address (`predictManagerAddress` gains an `initData`
  parameter). Counterfactual funding is now safe by construction.

### Added

- **`LPManagerFactory.createManagerNondeterministic`** (task_033) — create a manager at a non-deterministic
  (CREATE) address when the counterfactual-funding flow isn't needed; same guards as `createManager`.
- **Native funding on manager creation** (task_033) — `createManager` / `createManagerNondeterministic` are
  now `payable` and forward any `msg.value` to the new manager (`ManagerFunded` event); atomic, so a
  reverted creation returns the ETH.

### Changed

- **Envelop-protocol-v2 event-model compatibility** (task_036). `EnvelopV2OracleType` is now emitted in the
  implementation **constructor** (per-impl declaration, like envelop's `WNFTV2Envelop721`) instead of per-clone
  in `initialize`. Added the `SmartWallet` ether-tracking events — `EtherReceived` (in `receive()`) and
  `EtherBalanceChanged` (via a `fixEtherBalance` modifier on every value-moving op: `withdrawTo`,
  `executeEncodedTxBatch`, and the Stable/Volatile allocate/reinvest/recenter/claimFees paths).
- **Factory queries the manager instead of hard-coding; Envelop deployment event** (task_035). The
  `LPManagerFactory` post-init owner check now reads the singleton token id from the manager
  (`m.ownerOf(m.TOKEN_ID())`) rather than a local `TOKEN_ID` constant, and the deployment event is now
  **`EnvelopV2Deployment(address indexed proxy, address indexed implementation, uint256 envelopOracleType)`**
  (replacing `ManagerCreated`), with `envelopOracleType` queried from the manager's `ORACLE_TYPE()`.
  **Breaking:** indexers keying on `ManagerCreated` must switch to `EnvelopV2Deployment`.

### Fixed

- **Reject zero-liquidity adds** — audit `2026-07-18` L-REG-1 (task_034). `allocate`/`reinvest`/`recenter`
  now revert `ZeroLiquidity` when the computed liquidity is `0` (previously, with `minLiquidity == 0`, a
  no-op add slipped through and a fresh salt registered a zero-liquidity "ghost" in `openSalts`). Guard
  added in the shared `_addLiquidity` / `_addLiquidityAt` helpers.

## [1.0.0] - 2026-06-29

First public release of **Envelop StableLP** — an NFT-owned, factory-cloned Uniswap v4 stable-LP manager.

### Added

- **StableLPManager** — clone-deployed, NFT-owned manager for a configured set of hookless stable pools
  (arbitrary pairs, including native-ETH), keyed `salt == poolId` (one position per pool).
- **StableLPFactory** — EIP-1167 minimal-proxy clones with atomic `clone + initialize` (deterministic
  CREATE2 address per owner/nonce); no uninitialized-clone front-run window.
- **Shared bases** — `V4PositionManager` (V4 unlock dispatcher, position registry, swap/settle/take) and
  `SingletonNFTOwned` (singleton-NFT auth + operators with O(1) splice-on-disable).
- **Operations** — `allocate` (auto-deploy idle balance), `allocateFrom` (deploy a named just-deposited
  stable, snapshot-guarded), `withdrawTo` (indirect drain via v4-native `take`), `reinvest` (compound
  fees), `claimFees` (harvest). Native-ETH pools supported.
- **Protocol fee** — constant 10% of realized fees only (principal never taxed), skimmed as **ERC-6909
  claims** to an immutable treasury; redeemed via **FeeRedeemer**.
- **On-chain metadata** — `WalletPositionDescriptor` renders the singleton NFT's live position portfolio
  (`tokenURI`), with ERC-4906 metadata-update events; **UniLens** read aggregator for frontends.
- **Per-clone NFT name** via `InitParams.name`, with a default fallback of `Envelop LP Uniswap Manager`
  when empty.
- **Complete NatSpec** across the public surface for clean explorer (Etherscan) rendering.
- **Tests** — unit suites (`test/StableLP*.t.sol`) plus a Base fork test exercising a native ETH/USDC
  pool against the live V4 PoolManager (`test/StableLPManager.fork.t.sol`, env-gated by `BASE_RPC`).
- **Deploy scripts** — `DeployStableLP` / `DeployDescriptor` / `CreateManager`, parameterized by
  `script/chain_params.json`, writing `deployments/<chainId>.json`.

### Security

- Three audit passes under `audits/` (`2026-05-17`, `2026-06-23`, `2026-06-29`).
- Fixed HIGH: a stablecoin blocklist/pause on the protocol treasury could revert the exit path and lock
  LP principal — resolved by skimming the protocol fee as ERC-6909 claims instead of an ERC-20 transfer.
- Hookless-only pool gate (pools with hooks are categorically rejected).

### Deployed

- Ethereum (1), Arbitrum One (42161), Base (8453), Unichain (130), and Unichain Sepolia (1301).
  See [Deployments](./README.md#deployments) / `deployments/<chainId>.json`.

[Unreleased]: https://github.com/dao-envelop/uni-smart-wallet/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/dao-envelop/uni-smart-wallet/releases/tag/v1.0.0
