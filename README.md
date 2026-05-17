# uniswap-smart-wallet

Foundry-based Solidity project. See [`CLAUDE.md`](./CLAUDE.md) for architecture and [`tasks/spec_JITLPWallet.md`](./tasks/spec_JITLPWallet.md) for the design spec.

## Installing submodules

Solidity dependencies (`forge-std`, `envelop-protocol-v2`, `v4-hooks-public`, and everything they pull in transitively) are vendored as git submodules under `lib/`. Nothing builds until they are initialized.

### Fresh clone

```bash
git clone --recurse-submodules <repo-url>
cd uniswap-smart-wallet
```

### Existing clone (or after switching branches)

```bash
git submodule update --init --recursive
```

### Pinning to the versions in `foundry.lock`

Submodule revisions are pinned in `foundry.lock`. To sync local submodules to those revisions:

```bash
forge install
```

### Updating to the latest tracked revisions

Only do this when intentionally bumping a dependency:

```bash
git submodule update --remote --recursive
```

After updating, run `forge build` to confirm everything still compiles, and commit the new submodule SHAs together with any `remappings.txt` / `foundry.lock` changes.

## Quick start

```bash
forge build --sizes
forge fmt --check
forge test -vvv
```

## Running tests

The suite is split by concern. Each file boots only the scaffolding it needs, so you can run a single concern without paying for the rest. See [`CLAUDE.md`](./CLAUDE.md) for the full test-layout table.

### Local tests (no network)

These need only the initialized submodules. They deploy a fresh in-memory `PoolManager` per suite.

```bash
forge test -vvv                                                          # everything (fork suite skips if BASE_RPC unset)
forge test --match-path "test/UniSmartWallet*.t.sol" -vvv                # all core wallet suites
forge test --match-path test/UniSmartWallet.t.sol -vvv                   # auth / operators / executeEncodedTx
forge test --match-path test/UniSmartWalletPoolWiring.t.sol -vvv         # constructor / unlock callback / hook policy
forge test --match-path test/UniSmartWalletOpenPosition.t.sol -vvv       # openPosition full paths
forge test --match-path test/UniSmartWalletExitPositions.t.sol -vvv      # close / decrease / poke + fee accrual via swaps
forge test --match-path test/PositionMath.t.sol -vvv                     # tick-math library
forge test --match-path test/DeployWallet.t.sol -vvv                     # deploy script + chain_params.json parser

forge test --match-test test_openPosition_byOperator_succeeds -vvv        # single test by name
```

### Fork tests (live Base V4 PoolManager)

`test/UniSmartWallet.fork.t.sol` runs against the production V4 `PoolManager` on Base (chain 8453) — it verifies the settle/take/unlock plumbing against the real contract instead of an in-test copy. It is **env-gated**: without `BASE_RPC` the entire suite is skipped, so `forge test` stays green in environments without an RPC.

```bash
# Skip (default — CI without secrets):
forge test --match-path test/UniSmartWallet.fork.t.sol -vvv

# Run against a Base RPC:
BASE_RPC=https://mainnet.base.org \
  forge test --match-path test/UniSmartWallet.fork.t.sol -vvv

# Pin a block for reproducibility (recommended; latest is non-deterministic):
BASE_RPC=https://mainnet.base.org BASE_FORK_BLOCK=23000000 \
  forge test --match-path test/UniSmartWallet.fork.t.sol -vvv
```

The fork suite **initializes its own hookless 0.01%-fee pool** so the wallet is the sole LP — fee accrual is deterministic regardless of production WETH/USDC pool state. Three tests cover the full lifecycle (open → swap → close), `pokePosition` fee collection, and `decreasePosition` partial close.
