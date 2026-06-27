# Task 003 — PoolManager wiring + hook policy + position state

> Commit ref: `#3`
> Branch: `feature/task-003-poolmanager-hooks-state`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Direct PoolManager integration*, § *Pool Selection & Validation* (on-chain), § *API Surface* (state + hook policy + views)
> Depends on: task 001 (`onlyOwnerNFT`)

## Goal

Wire the wallet to a V4 `PoolManager` immutably, install the `unlockCallback` dispatcher skeleton (stubs revert until tasks 004–005 fill them in), expose the hook-whitelist policy that `openPosition` will consult, and lay down the position registry.

## Scope (in this task)

1. **Constructor + immutable**:
   - Switch existing `address _poolManager` arg to `IPoolManager poolManager_` (`@uniswap/v4-core/src/interfaces/IPoolManager.sol`).
   - Store as `IPoolManager public immutable POOL_MANAGER`.
   - Update task-001 / task-002 tests' deploy helper accordingly.
2. **`IUnlockCallback` skeleton** (`@uniswap/v4-core/src/interfaces/IUnlockCallback.sol`):
   - Inherit the interface.
   - `enum Op { OPEN, CLOSE, DECREASE, POKE }`.
   - `function unlockCallback(bytes calldata data) external returns (bytes memory)`:
     - `require(msg.sender == address(POOL_MANAGER), "NotPoolManager")`.
     - Decode `(Op op, bytes payload) = abi.decode(data, (Op, bytes))`.
     - Dispatch to `_handleOpen` / `_handleClose` / `_handleDecrease` / `_handlePoke` — each internal stub reverts with `"NotImplemented"` for now.
3. **Hook policy**:
   - `mapping(address => bool) public allowedHooks` — constructor seeds `allowedHooks[address(0)] = true`.
   - `address public hookRegistry` (zero ⇒ registry check skipped).
   - `function setHookAllowed(address hook, bool allowed) external onlyOwnerNFT` + `HookAllowed(hook, allowed)` event.
   - `function setHookRegistry(address registry) external onlyOwnerNFT` + `HookRegistrySet(registry)` event.
   - Internal helper `function _isHookAllowed(address hook) internal view returns (bool)` consolidating local whitelist + (if `hookRegistry != address(0)`) `IHookRegistry(hookRegistry).isAllowed(hook)`. Reused by task 004.
4. **`IHookRegistry` interface** in a **new** file `src/interfaces/IHookRegistry.sol`:
   ```solidity
   interface IHookRegistry { function isAllowed(address hook) external view returns (bool); }
   ```
5. **Position storage**:
   - `struct Position { PoolKey key; int24 tickLower; int24 tickUpper; uint128 liquidity; uint64 openedAt; }`.
   - `mapping(bytes32 => Position) public positions`.
   - `bytes32[] public openSalts` (enumerable list).
6. **Views**:
   - `function positionOf(bytes32 salt) external view returns (Position memory)`.
   - `function openPositionCount() external view returns (uint256)`.
   - `function ownerNFTHolder() external view returns (address)` returning `ownerOf(TOKEN_ID)`.
7. **Tests** appended to `test/UniSmartWallet.t.sol`:
   - `test_unlockCallback_rejectsNonPoolManager`
   - `test_setHookAllowed_byOwner_succeeds`
   - `test_setHookAllowed_byNonOwner_reverts`
   - `test_hookAllowedZeroSeededByConstructor`
   - `test_hookRegistryZero_fallsBackToLocalWhitelist`
   - `test_setHookRegistry_blocksWhenRegistryRejects` (mock `IHookRegistry` returning `false`)
   - `test_views_emptyPosition`

## Out of scope

- Actual `openPosition` / `closePosition` / `decreasePosition` / `pokePosition` external functions and their callback bodies → tasks 004–005.
- Position math, slippage, settle/take → tasks 004–005.

## Files to add / change

| Path | Change |
|---|---|
| `src/UniSmartWallet.sol` | Constructor signature → `IPoolManager`, inherit `IUnlockCallback`, `Op` enum + dispatcher with stubbed handlers, hook policy state + setters + `_isHookAllowed`, position storage + views |
| `src/interfaces/IHookRegistry.sol` | New file |
| `test/helpers/Mocks.sol` | **New shared mocks file** — `MockERC20` + `Echo` (extracted from `test/UniSmartWallet.t.sol`) and new `MockHookRegistry` |
| `test/UniSmartWallet.t.sol` | Import shared mocks instead of inline; update deploy helper for `IPoolManager` constructor arg |
| `test/UniSmartWalletPoolWiring.t.sol` | **New file** with the 14 task-003 tests (constructor wiring, unlock-callback gating + dispatch routing, hook setters/auth, `_isHookAllowed` branches via a `UniSmartWalletHookHarness`, views) |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path "test/UniSmartWallet*.t.sol" -vvv
```

All 18 task-001/002 tests still pass (after constructor cast to `IPoolManager`) and the 14 new task-003 tests in `test/UniSmartWalletPoolWiring.t.sol` pass.

## Notes for implementer

- The dispatcher is intentionally a placeholder: it must compile and reject non-PoolManager callers now so the security boundary is testable. The actual op handlers are filled in by task 004 (`OPEN`) and task 005 (`CLOSE` / `DECREASE` / `POKE`).
- Use OZ v5 custom error or string revert consistently with the rest of the contract.
- `PoolKey` import: `@uniswap/v4-core/src/types/PoolKey.sol`.
- Don't add `StateLibrary` usage here — that comes in task 004 along with `_isHookAllowed` consumers.
