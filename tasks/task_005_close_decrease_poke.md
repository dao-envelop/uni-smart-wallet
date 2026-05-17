# Task 005 — `closePosition` + `decreasePosition` + `pokePosition`

> Commit ref: `#5`
> Branch: `feature/task-005-close-decrease-poke`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Architecture Overview* (close / poke), § *API Surface* (close/decrease/poke)
> Depends on: tasks 001–004

## Goal

Three exit-side primitives that share the unlock-callback skeleton and the `_take` plumbing — bundled because splitting them produces near-empty commits with duplicated test scaffolding.

## Scope (in this task)

1. **`closePosition`**:
   ```solidity
   function closePosition(bytes32 salt) external onlyAuthorized nonReentrant;
   ```
   - Load `Position memory p = positions[salt]; require(p.liquidity > 0, "Unknown");`.
   - Dispatch `Op.CLOSE` with `(p.key, p.tickLower, p.tickUpper, p.liquidity, salt)`.
   - Callback `_handleClose`: `modifyLiquidity(-int256(uint256(p.liquidity)))` → take principal from both currencies via `poolManager.take` to `address(this)`.
   - Splice `salt` out of `openSalts`, `delete positions[salt]`.
   - Emit `PositionClosed(salt, principal0, principal1, fees0, fees1)`. Use the second `BalanceDelta` returned by `modifyLiquidity` for fees.
2. **`decreasePosition`**:
   ```solidity
   function decreasePosition(bytes32 salt, uint128 deltaLiquidity)
       external onlyAuthorized nonReentrant;
   ```
   - `require(deltaLiquidity > 0 && deltaLiquidity <= positions[salt].liquidity, "BadDelta");`.
   - Dispatch `Op.DECREASE`; callback runs `modifyLiquidity(-int256(uint256(deltaLiquidity)))` and takes.
   - Update `positions[salt].liquidity -= deltaLiquidity` (do not delete; position survives).
   - Emit `PositionDecreased(salt, deltaLiquidity, taken0, taken1, fees0, fees1)`.
3. **`pokePosition`**:
   ```solidity
   function pokePosition(bytes32 salt) external onlyAuthorized nonReentrant;
   ```
   - Dispatch `Op.POKE`; callback runs `modifyLiquidity(0)` to release the fees-owed delta only, takes fees, leaves `liquidity` untouched.
   - Emit `FeesCollected(salt, fees0, fees1)`.
4. **Tests** appended to `test/UniSmartWallet.t.sol`:
   - `test_closePosition_byNFTOwner_succeeds_returnsCapitalPlusFees`
   - `test_closePosition_byOperator_succeeds`
   - `test_closePosition_byNonAuthorized_reverts`
   - `test_closePosition_unknownSalt_reverts`
   - `test_decreasePosition_partial_succeeds`
   - `test_decreasePosition_overFlowDelta_reverts`
   - `test_decreasePosition_zeroDelta_reverts`
   - `test_pokePosition_collectsFeesOnly`
   - `test_openMultiplePositions_independentSalts` — open with three salts, close out-of-order, registry stays consistent.

## Out of scope

- Fork tests against a live PoolManager → task 007.
- Deploy script → task 006.

## Files to add / change

| Path | Change |
|---|---|
| `src/UniSmartWallet.sol` | Add three external functions + their internal `_handleClose` / `_handleDecrease` / `_handlePoke` bodies; remove `"NotImplemented"` stubs from task 003 |
| `test/UniSmartWallet.t.sol` | Append the 9 tests; helper that simulates a swap through the position's range so fees actually accrue |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path test/UniSmartWallet.t.sol -vvv
```

All listed tests pass; full prior suite still passes.

## Notes for implementer

- `modifyLiquidity` returns `(BalanceDelta delta, BalanceDelta feesAccrued)`; on the close path, principal = `delta - feesAccrued` (be careful with the sign convention — V4 returns positive amounts when we're owed).
- `openSalts` splice: swap-and-pop is fine since order doesn't matter; just `if (idx != openSalts.length - 1) openSalts[idx] = openSalts[openSalts.length - 1]; openSalts.pop();`. Track per-salt index in a `mapping(bytes32 => uint256) private _saltIndex` to keep the splice O(1).
- For the fee-accrual tests in `setUp`, route a swap from a separate signer through the deployed PoolManager so `feeGrowthInside` for our range advances; use `PoolSwapTest` from `v4-core/test/utils` if convenient.
