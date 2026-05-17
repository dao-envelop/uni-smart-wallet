# Task 002 — Capital management (deposits + withdrawals)

> Commit ref: `#2`
> Branch: `feature/task-002-capital-management`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Capital flow*, § *API Surface* (capital management block)
> Depends on: task 001 (`onlyOwnerNFT`)

## Goal

Let anyone fund the wallet (donation-friendly) while restricting withdrawals to the singleton-NFT holder. Add `ReentrancyGuard` to the withdraw paths.

## Scope (in this task)

1. **Inherit `ReentrancyGuard`** (`@openzeppelin/contracts/utils/ReentrancyGuard.sol`). Update the constructor / inheritance list accordingly.
2. **Deposits (anyone)**:
   - `receive() external payable` — bare native deposit.
   - `function depositERC20(address token, uint256 amount) external` — pull pattern via `IERC20.transferFrom(msg.sender, address(this), amount)`. Emit `ERC20Deposited(token, msg.sender, amount)`.
3. **Withdrawals (owner only, reentrancy-guarded)**:
   - `function withdrawERC20(address token, uint256 amount, address to) external onlyOwnerNFT nonReentrant` — uses `SafeERC20.safeTransfer`. Emit `ERC20Withdrawn(token, to, amount)`.
   - `function withdrawNative(uint256 amount, address payable to) external onlyOwnerNFT nonReentrant` — uses `to.call{value: amount}("")` and reverts on failure. Emit `NativeWithdrawn(to, amount)`.
4. **Tests** appended to `test/UniSmartWallet.t.sol`:
   - `test_receiveNative_anyoneCanDeposit`
   - `test_depositERC20_anyoneCanDeposit`
   - `test_withdrawERC20_byNFTOwner_succeeds`
   - `test_withdrawERC20_byNonOwner_reverts`
   - `test_withdrawNative_byNFTOwner_succeeds`
   - `test_withdrawNative_byNonOwner_reverts`
   - `test_withdrawNative_reentrancyProbe_reverts` — malicious `to` re-enters `withdrawNative`; expect revert.

## Out of scope

- Anything that involves PoolManager-side balances (settle/take) → task 004/005.
- Native vs WETH handling inside the V4 unlock callback → task 004/005.

## Files to add / change

| Path | Change |
|---|---|
| `src/UniSmartWallet.sol` | Add `ReentrancyGuard`, deposit/withdraw functions, events |
| `test/UniSmartWallet.t.sol` | Append 7 capital tests; introduce a `MockERC20` helper if not already imported via forge-std / OZ mocks |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path test/UniSmartWallet.t.sol -vvv
```

All capital tests pass and prior task-001 tests still pass.

## Notes for implementer

- Use `SafeERC20.safeTransfer` (`@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`) instead of bare `transfer` to handle tokens that don't return `bool`.
- The reentrancy test should deploy a tiny attacker contract whose `receive()` re-enters `withdrawNative`; assert it reverts with `ReentrancyGuardReentrantCall` (OZ v5 error).
- Donation-friendly `receive()` means no `onlyOwnerNFT` here — that's by design (per spec).
