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
