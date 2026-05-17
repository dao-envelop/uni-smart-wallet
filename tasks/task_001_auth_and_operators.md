# Task 001 — Singleton-NFT hardening + operator delegation

> Commit ref: `#1` (per `AGENTS.md`, leading three digits → `#N`)
> Branch: `feature/task-001-auth-and-operators`
> Source of truth: `tasks/spec_JITLPWallet.md` § *Authorization: Singleton NFT pattern*, § *Operator delegation*, § *NFT transfer semantics*

## Goal

Lock the ERC-721 ownership contract so the auth root is exactly one non-burnable, non-duplicable token — and let the NFT holder delegate operational rights to bots without giving them custody. Wallet-control transfer atomically clears prior delegations.

## Scope (in this task)

1. **Singleton invariant** in `src/UniSmartWallet.sol`:
   - Override `_update` / `_mint` so a second `_mint` call (after the constructor) reverts.
   - Override `_burn` (or the relevant OZ v5 hook) so burning the singleton reverts.
2. **Auth modifiers**:
   - `modifier onlyOwnerNFT()` → `ownerOf(TOKEN_ID) == msg.sender`.
   - `modifier onlyAuthorized()` → owner NFT holder *or* `operators[msg.sender]`.
3. **Operator registry**:
   - `mapping(address => bool) public operators`.
   - `address[] internal _operatorList` to enumerate for auto-clear on NFT transfer.
   - `function setOperator(address op, bool allowed) external onlyOwnerNFT` emits `OperatorSet(op, allowed)`.
4. **Auto-clear on transfer**: extend the `_update` override to iterate `_operatorList` and reset `operators[*] = false` whenever the NFT changes hands.
5. **Tests** in `test/UniSmartWallet.t.sol` (created in this task):
   - `test_singletonNFT_cannotMintMore`
   - `test_singletonNFT_cannotBurn`
   - `test_nftTransfer_handsOverControl`
   - `test_nftTransfer_clearsOperators`
   - `test_setOperator_byOwner_succeeds`
   - `test_setOperator_byNonOwner_reverts`

## Out of scope

- Capital management (`receive` / `depositERC20` / `withdrawERC20` / `withdrawNative`) → task 002.
- Any `PoolManager` wiring or position storage → task 003.
- `onlyAuthorized` is added now but is unused until task 003 starts dispatching position ops.

## Files to add / change

| Path | Change |
|---|---|
| `src/UniSmartWallet.sol` | Add singleton overrides, operator state, modifiers, `setOperator`, `_update` auto-clear |
| `test/UniSmartWallet.t.sol` | New file, 6 unit tests listed above |

## Acceptance

```bash
forge fmt --check
forge build --sizes
forge test --match-path test/UniSmartWallet.t.sol -vvv
```

All 6 listed tests pass. CI workflow (`.github/workflows/test.yml`) is green.

## Notes for implementer

- OpenZeppelin v5 ERC-721 uses `_update(address to, uint256 tokenId, address auth)`; the auth-clear logic lives there, *not* in `_beforeTokenTransfer` (removed in v5).
- The constructor already mints `TOKEN_ID = 1`; keep that ID stable for compatibility with the Envelop oracle events.
- Use a dedicated boolean (`bool private _minted;` set in constructor) to enforce "post-constructor mints revert"; do not key off `_ownerOf(TOKEN_ID) != address(0)` alone since transfers leave it set anyway.
