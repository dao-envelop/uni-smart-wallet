# task_025 — Remove UniSmartWallet, extract BaseLPManager, re-parent StableLPManager

**Priority:** High · **Effort:** L · **Part of:** volatile-manager + multi-impl-factory initiative
(see plan). First task in the chain; prerequisite cleanup + shared-base extraction.

## Goal
Retire the `UniSmartWallet` JIT-LP wallet product, trim `V4PositionManager` to the manager-used
surface, and extract a shared abstract **`BaseLPManager`** that `StableLPManager` (and, later,
`VolatileLPManager`) subclass. Driver: minimize audited attack surface. **Hard gate:** every contract
stays `< 24 576` B runtime (`forge build --sizes`).

## Baseline (confirmed this task, `forge build --sizes`)
StableLPManager **24 226 / 24 576 (350 free)** · UniSmartWallet 17 939 · WalletPositionDescriptor
18 942 · UniLens 7 483 · StableLPFactory 1 545 · FeeRedeemer 2 728 · PositionMath 2 147.
Note: removing UniSmartWallet does NOT shrink the managers (its base ops are already dead-stripped
from StableLPManager) — the win is audit surface, not bytecode.

## Dependency analysis (done)
- `UniLens.sol`, `WalletPositionDescriptor.sol`, `DeployDescriptor.s.sol` reference UniSmartWallet
  **only in comments** — typed against generic `V4PositionManager`; keep working for managers.
- **Test scaffolding is the real coupling:** `test/helpers/V4WalletTestBase.sol` deploys a
  UniSmartWallet as the NFT-owned position vehicle, and these SHARED tests depend on it:
  `WalletPositionDescriptor.t.sol`, `UniLens.t.sol`, `PositionState.t.sol` (all need an NFT-owned
  `V4PositionManager` with a descriptor + a way to open positions with chosen ranges/liquidity).
- `test/V4PositionManager.t.sol` uses `V4PositionManagerHarness` which calls the base
  `_openPosition` (the explicit-liquidity path we intend to trim) — so the harness must own that
  path if the base loses it.

## Plan (keep the suite green at every commit)
1. **New test vehicle** `test/helpers/NFTPositionHarness.sol` = `SingletonNFTOwned` +
   `V4PositionManager` + a public `open(...)`/`close(...)` + `setDescriptor` + `tokenURI`. Replaces
   UniSmartWallet as the NFT-owned test subject. Repoint `V4WalletTestBase` to deploy it; update the
   `wallet`-typed refs in the 3 shared tests to the harness type.
2. **Delete pure-wallet artifacts:** `src/UniSmartWallet.sol`; tests `UniSmartWallet.t.sol`,
   `UniSmartWalletPoolWiring.t.sol`, `UniSmartWalletOpenPosition.t.sol`,
   `UniSmartWalletExitPositions.t.sol`, `UniSmartWalletNativePosition.t.sol`,
   `UniSmartWallet.fork.t.sol`, `DeployWallet.t.sol`; `script/DeployWallet.s.sol`;
   `tasks/spec_JITLPWallet.md`. Drop the UniSmartWallet mentions from the 3 comment-only files.
3. **Trim `V4PositionManager`** to manager-used primitives: remove the explicit-liquidity open path
   (`_openPosition`/`_unlockOpen`/`OpenParams`/`_handleOpen`) and the standalone
   close/decrease/poke ops + their events (`PositionOpened`/`PositionClosed`/`PositionDecreased`) —
   relocating any open/close needed for tests into the harness. Keep `_withdrawLiquidity`, `_swap`,
   `_settle`, `_take`, `_takeClaim`, the registry + `_registerSalt`/`_removeSalt`,
   `_pokePosition`/`_unlockRemove`/`RemoveParams`, `FeesCollected`, `ExceedsAmount0Max/1Max`, views,
   hookless gate. (Optional: collapse `V4PositionManager` into `BaseLPManager` since the wallet was
   the reason for the split.)
4. **Extract `BaseLPManager`** (abstract): move the manager-common surface out of `StableLPManager`
   — clone-init hook, `managedStables` union, protocol-fee skim, indirect `withdrawTo`,
   descriptor/`tokenURI`, Envelop events, extensible op-dispatch — with **virtual seams**
   (`_allocateLeg`, `_addLiquidity`, range source). Make `StableLPManager` a **behavior-preserving**
   subclass (stable tests unchanged & green). Declare the common external interface
   (`allocate`/`withdrawTo`/`reinvest`/`claimFees`/`setOperator`/`initialize`/views) on the base so
   `VolatileLPManager` can match it (decision 6).

## Acceptance
- `forge build --sizes`: all contracts `< 24 576`; StableLPManager unchanged in behavior, size not
  worse (record the number).
- `forge fmt --check` clean; `forge test -vvv` green (reworked descriptor/lens/positionstate suites +
  all StableLP* suites). No remaining references to `UniSmartWallet`/`DeployWallet` in `src`/`test`/`script`.
- `BaseLPManager` exists; `StableLPManager` is a subclass with identical external ABI + behavior.

## Notes
- Re-parenting StableLPManager changes a **live, audited** contract → re-audit + redeploy for new
  clones (existing immutable clones unaffected). Existing on-chain UniSmartWallet deploys are untouched.
- Step 4 (base extraction) is the riskiest; land steps 1–3 (removal + trim) green first, then extract.
