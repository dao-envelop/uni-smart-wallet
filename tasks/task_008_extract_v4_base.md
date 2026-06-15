# Task 008 — Extract a reusable Uniswap V4 abstraction (`V4PositionManager`)

## Goal

`UniSmartWallet` is a PoC for direct Uniswap V4 interaction. The real product line (first member: `StableLPManager`, see `tasks/spec_StableLPManager.md`) needs the same V4 mechanics. Instead of forking, extract the V4 interaction layer (LP position management + swaps) into a shared abstract base that both `UniSmartWallet` and the upcoming `StableLPManager` inherit.

This task is the **foundation only**: the abstraction + refactor of `UniSmartWallet` to use it + base-layer tests. `StableLPManager`, its factory, and extracting the singleton-NFT auth base are follow-up tasks.

## Scope

1. New `abstract contract V4PositionManager` (`src/abstract/V4PositionManager.sol`) holding all V4 mechanics moved out of `UniSmartWallet`:
   - types/errors/events (`Op`, `Position`, `OpenParams`, `RemoveParams`, position/hook errors and events);
   - state (`positions`, `openSalts`, `_saltIndexPlusOne` → `internal`, `allowedHooks`, `hookRegistry`);
   - `unlockCallback` dispatcher (extensible via `_dispatchExtraOp`), `_handleOpen/_handleClose/_handleDecrease/_handlePoke`, `_withdrawLiquidity`, `_removeSalt`, `_isHookAllowed`;
   - internal action fns `_openPosition/_closePosition/_decreasePosition/_pokePosition` (validation + `unlock`);
   - new `_swap` primitive + `_settle`/`_take` helpers;
   - `positionOf`/`openPositionCount` views;
   - `_poolManager()` virtual (deployment-model seam: immutable for the wallet, storage for clones).
2. Refactor `UniSmartWallet` to `is SmartWallet, ERC721, V4PositionManager`, keeping identity/auth/custody + thin public wrappers. Behavior must be **identical**; all existing tests pass unchanged.
3. New base-layer tests via a minimal ungated harness (`test/helpers/V4PositionManagerHarness.sol`, `test/V4PositionManager.t.sol`).

## Out of scope

- `StableLPManager` / `StableLPFactory` / `WithdrawForwarder`.
- Extracting singleton-NFT + operator auth into its own base (follow-up).

## Verification

- `forge build --sizes`, `forge fmt --check`.
- `forge test --match-path "test/UniSmartWallet*.t.sol" -vvv` + `test/PositionMath.t.sol` + `test/DeployWallet.t.sol` (all unchanged).
- New `test/V4PositionManager.t.sol`: open→close roundtrip, slippage-cap reverts, unknown-op revert via `_dispatchExtraOp`, swap+add netting, O(1) salt splice.
- Fork suite env-gated by `BASE_RPC`.
