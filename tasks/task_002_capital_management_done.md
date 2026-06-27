# Task 002 — Expose SmartWallet execute primitives to NFT owner

> Commit ref: `#2` (per `AGENTS.md`, leading three digits → `#N`)
> Branch: `feature/task-002-capital-management` (off `feature/task-001-auth-and-operators`)
> Source of truth: `tasks/spec_JITLPWallet.md` § *Capital flow*, § *API Surface* (capital management block) — with intentional deviation, see *Design note* below.
> Depends on: task 001 (`onlyOwnerNFT`)

## Goal

Let the singleton-NFT holder move funds out (native + any ERC-20), claim airdrops, approve spenders, and chain calls — without growing the contract API beyond the bare minimum. The parent `SmartWallet` already implements all the plumbing; this task only exposes it.

## Design note (departure from spec)

The spec lists four dedicated functions: `receive() payable`, `depositERC20`, `withdrawERC20`, `withdrawNative`. We deliberately do **not** add any of them:

- **Deposits don't need wallet-side functions.** ERC-20 has no receiver hook — anyone calling `IERC20.transfer(walletAddress, amount)` updates the wallet balance and the token emits its own indexed `Transfer` event. Native deposits already work via the inherited `SmartWallet.receive()` which emits `EtherReceived(balance, value, sender)`.
- **Withdrawals are a special case of arbitrary execution.** The parent `SmartWallet._executeEncodedTx(target, value, data)` (with the `fixEtherBalance` modifier emitting `EtherBalanceChanged`) already covers both: `withdrawNative` ≡ `executeEncodedTx(payable(to), amount, "")`; `withdrawERC20` ≡ `executeEncodedTx(token, 0, abi.encodeCall(IERC20.transfer, (to, amount)))`. One generic primitive is strictly more useful than two narrow ones — the owner also gets claim-airdrop, approve-spender, call-dApp, and multi-step composition for free.

The trade-off is auditing surface: arbitrary `call` from a privileged role is harder to reason about statically than narrow withdrawals. We accept this because (a) the parent `SmartWallet` is the audited Envelop-V2 execution primitive and we're just relaying through it, (b) the NFT holder is by definition trusted with the entire wallet, and (c) the alternative is reimplementing functionality that already exists.

## Scope (in this task)

1. **External wrappers** in `src/UniSmartWallet.sol`:
   ```solidity
   function executeEncodedTx(address target, uint256 value, bytes calldata data)
       external onlyOwnerNFT returns (bytes memory);

   function executeEncodedTxBatch(
       address[] calldata targets,
       uint256[] calldata values,
       bytes[] calldata datas
   ) external onlyOwnerNFT returns (bytes[] memory);
   ```
   Each just forwards to `super._executeEncodedTx(...)` / `super._executeEncodedTxBatch(...)`. Inherits parent-side `fixEtherBalance` accounting and the `DifferentArraysLength` revert.
2. **Authorization stays narrow**: `onlyOwnerNFT` only. Operators do **not** get arbitrary execution — that would defeat the "operators cannot drain capital" property of the delegation model from task 001.
3. **No `nonReentrant`** on the execute functions. The owner is trusted; position-side reentrancy is handled by the per-op `nonReentrant` planned in tasks 004 / 005.
4. **Tests** appended to `test/UniSmartWallet.t.sol` (introduces a minimal `MockERC20` + `Echo` helper contract):
   - `test_anyoneCanDepositNative` — random EOA sends ETH via `address(wallet).call{value: …}("")`; assert balance + `EtherReceived` event from `SmartWallet.receive()`.
   - `test_anyoneCanDepositERC20` — random EOA does `mock.transfer(address(wallet), amt)`; assert wallet balance.
   - `test_executeEncodedTx_withdrawNative_byOwner_succeeds` — owner calls `executeEncodedTx(payable(alice), 1 ether, "")`; assert alice's balance + `EtherBalanceChanged` event.
   - `test_executeEncodedTx_withdrawERC20_byOwner_succeeds` — owner calls `executeEncodedTx(token, 0, abi.encodeCall(IERC20.transfer, (alice, amt)))`; assert balances.
   - `test_executeEncodedTx_byNonOwner_reverts` — Alice (non-owner) call reverts with `NotOwnerNFT`.
   - `test_executeEncodedTx_byOperator_reverts` — `setOperator(bot, true)` then `bot` calls execute → `NotOwnerNFT`. Locks the "operators cannot drain" invariant.
   - `test_executeEncodedTx_arbitraryCall_returnsData` — calls `Echo.ping(bytes)` and checks returned bytes round-trip.
   - `test_executeEncodedTxBatch_multipleActions_succeeds` — batch: approve + transfer + transfer; assert final state.
   - `test_executeEncodedTxBatch_arrayMismatch_reverts` — expect the parent's `DifferentArraysLength` error.
   - `test_executeEncodedTxBatch_byNonOwner_reverts`.

## Out of scope

- Anything PoolManager-related → tasks 003–005.
- Withdrawal-specific events beyond what `fixEtherBalance` already emits.
- Receiver hooks for ERC-721 / ERC-1155 deposits — the parent `SmartWallet` already inherits `ERC721Holder` and `ERC1155Holder`, so this just works.

## Files to add / change

| Path | Change |
|---|---|
| `tasks/task_002_capital_management.md` | Rewrite (this file) to record the intentional deviation from spec |
| `src/UniSmartWallet.sol` | Add `executeEncodedTx` + `executeEncodedTxBatch` external wrappers |
| `test/UniSmartWallet.t.sol` | Append 10 tests + `MockERC20` + `Echo` helper contracts |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path test/UniSmartWallet.t.sol -vvv
```

All 8 task-001 tests + the 10 new task-002 tests pass.

## Notes for implementer

- `IERC20` import: `@openzeppelin/contracts/token/ERC20/IERC20.sol` (already resolvable through the existing remapping).
- `MockERC20` for tests: `lib/forge-std/src/mocks/MockERC20.sol` ships one — use it instead of hand-rolling.
- The `Echo` helper is a 5-line contract: `function ping(bytes calldata data) external pure returns (bytes calldata) { return data; }` — define it inside the test file.
- Don't bother re-emitting events from the wrappers; the parent already emits `EtherBalanceChanged` on any value movement.
