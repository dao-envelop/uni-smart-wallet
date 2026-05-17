# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Commands

Foundry-based project. Submodules must be initialized before anything builds:

```bash
git submodule update --init --recursive
```

Day-to-day:

```bash
forge build --sizes          # mirrors CI (`.github/workflows/test.yml`)
forge fmt --check            # CI fails on unformatted files; use `forge fmt` to fix
forge test -vvv              # run all tests
forge test --match-test <name> -vvv
forge test --match-path test/UniSmartWallet.t.sol -vv
forge test --fork-url $BASE_RPC --match-path test/UniSmartWallet.fork.t.sol
```

`foundry.toml` enables `ffi = true` and sets `solc = 0.8.26`, `evm = cancun`, `optimizer_runs = 800`, `via_ir = false`. RPC endpoints (`mainnet`, `arbitrum`, `optimism`, `polygon`, `avalanche`, `sepolia`) and Etherscan keys are wired from env vars — see the `[rpc_endpoints]` and `[etherscan]` blocks for the exact variable names before running fork tests or `forge verify-contract`.

## Architecture

The repo is the implementation home of **UniSmartWallet**, a contract that fuses three things:

1. **Envelop V2 `SmartWallet` base** (`@envelop-v2/src/impl/SmartWallet.sol`) — provides the asset-custody surface and the `ERC1155Holder` mixin that forces the `supportsInterface` override.
2. **OpenZeppelin `ERC721`** — the wallet *is* an NFT contract that mints a **singleton ownership token** (`TOKEN_ID = 1`) at deploy. Whoever holds that one NFT controls the wallet; transferring it atomically hands over wallet control. There is no `Ownable`/admin pattern — the NFT *is* the auth root.
3. **Uniswap V4 direct `PoolManager` integration** — the wallet will implement `IUnlockCallback` and call `poolManager.unlock(...)` itself (no `PositionManager`, no NFT-per-position). Positions are keyed by a caller-chosen `bytes32 salt`, not by `tokenId`.

`src/UniSmartWallet.sol` today is the scaffold: constructor mints the singleton NFT, emits Envelop oracle-compatibility events (`EnvelopV2OracleType`, `EnvelopWrappedV2`, `IERC4906.MetadataUpdate`), and overrides `supportsInterface` across both parent hierarchies. The full design (capital ops, `openPosition` / `closePosition` / `decreasePosition` / `pokePosition`, operator delegation, hook whitelist, slippage bounds) lives in **`tasks/spec_JITLPWallet.md`** — read that before changing or extending the contract.

### Envelop oracle compatibility

The constructor emits `EnvelopV2OracleType(ORACLE_TYPE=2002, ...)` and `EnvelopWrappedV2(...)`. These exist purely so existing Envelop V2 oracles index this contract. Do **not** rename or drop them without coordinating with the Envelop side.

### Submodules and remappings

Solidity dependencies are pulled via git submodules under `lib/` (`forge-std`, `envelop-protocol-v2`, `v4-hooks-public`). The bulk of `remappings.txt` re-exports paths *through* `v4-hooks-public` — meaning OZ, Uniswap v2/v3/v4 core/periphery, Permit2, Solady, etc. all resolve into nested subdirectories of `lib/v4-hooks-public/lib/...`. Two top-level remappings to know:

- `@envelop-v2/` → `lib/envelop-protocol-v2/`
- `@openzeppelin/contracts/` → `lib/v4-hooks-public/lib/openzeppelin-contracts/contracts/` (do **not** add a separate OZ submodule — use the one bundled under v4-hooks-public)

If you add a new dependency, add it as a submodule and extend `remappings.txt`; don't introduce a parallel OZ/Uniswap copy.

### Task and branch workflow

See `AGENTS.md`: every task lives in `tasks/task_NNN.md`, is solved on a new branch, and the leading 3-digit number becomes `#<n>` in the commit message. Confirm which task file to work on **before** starting.
