# Task 033 — LPManagerFactory hardening (audit L-FAC-1) + create options

Follow-up to `audits/2026-07-18`. All changes in `src/LPManagerFactory.sol`.

## 1. L-FAC-1 — bind `initData` into the CREATE2 salt
The deterministic clone address depended only on `(expectedOwner, implementation, nonce)`, not on
`initData`. A front-runner could deploy a DIFFERENT config (`initData`) at a caller's predicted,
pre-funded address (counterfactual-funding front-run). No theft (funds recoverable via the owner escape
hatch) but a griefing/mis-config vector.

Fix: `salt = keccak256(abi.encode(expectedOwner, implementation, n, keccak256(initData)))` in
`createManager`, mirrored in `predictManagerAddress` — which now takes a `bytes calldata initData`
parameter (must be the same calldata the deployment will use). A substituted `initData` now yields a
different address, so counterfactual funding is safe by construction.

## 2. `createManagerNondeterministic(implementation, expectedOwner, initData)`
New entry point that clones via `Clones.clone` (CREATE, not CREATE2). The address is not caller-
predictable, so there is no pre-funded address to substitute config at. Same guards (allowlist, atomic
init with bubbled revert, post-init `ownerOf(TOKEN_ID) == expectedOwner`). Does not consume the per-owner
`nonce` (keeps the deterministic predict-numbering clean); emits `ManagerCreated` with
`nonce = type(uint256).max` (documented N/A sentinel).

## 3. Native forwarding on creation
Both create entry points are now `payable`. After the owner-check passes, any `msg.value` is forwarded to
the new manager via `Address.sendValue(payable(manager), msg.value)` (hits `BaseLPManager.receive()`),
emitting a new `ManagerFunded(manager, value)` event. Atomic — a failed send / init reverts the whole
creation, so no ETH is stranded.

Shared init+check+fund+emit logic lives in internal `_initAndFund(...)`, called by both public functions.

## Tests
- `test/LPManagerFactory.t.sol` — update `predictManagerAddress` calls to the new 4-arg signature.
- `test/LPManagerFactoryCreate.t.sol` (new) — same `(owner,impl,nonce)` + different `initData` ⇒ different
  address; `predictManagerAddress(...,initData)` matches the actual deploy; `createManagerNondeterministic`
  mints the singleton to `expectedOwner` at an address ≠ deterministic; native forwarding
  (`createManager{value:X}` / `createManagerNondeterministic{value:X}` ⇒ manager balance == X; `value==0`
  ⇒ no forward; reverting init with value ⇒ ETH returned, not stranded).

## Verification
```bash
forge fmt --check
forge build --sizes
forge test --match-path "test/LPManagerFactory*.t.sol" -vvv
forge test
```
</content>
