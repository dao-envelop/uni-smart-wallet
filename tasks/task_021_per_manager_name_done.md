# Task 021 — Per-manager NFT `name` via `initialize` (variant C: `bytes32`)

## Goal

Let each `StableLPManager` clone carry its own NFT `name` instead of the shared `pure` constant
`"Envelop StableLP"`. The name is supplied by the factory caller at creation and surfaced via the
ERC-721 `name()` (and the on-chain descriptor metadata / UI).

## Decision: variant C (`bytes32`, ≤31 chars)

Chosen because the implementation is EIP-170-tight. Measured with `forge build --sizes`
(solc 0.8.26, `optimizer_runs=800`, `via_ir=false` — via-IR can't be enabled: v4 `PoolManager`
stack-too-deep):

| Approach | Runtime size | Δ vs baseline | Margin (limit 24,576) |
| --- | --- | --- | --- |
| Baseline (`name()` pure constant) | 23,972 | — | 604 |
| A — dynamic `string` in initialize | 24,409 | +437 | 167 |
| **C — `bytes32` (≤31 chars)** | **24,233** | **+261** | **343** |
| D — keep constant, name only in descriptor JSON | 23,972 | 0 | 604 |

Variant A leaves only 167 B headroom (too tight); C costs ~half (+261 B, 343 B left) at the price of
a 31-char cap, which is ample for names like "Envelop StableLP". (If the name is only ever needed in
NFT metadata/UI, variant D is free — the descriptor JSON already returns a `name` — keep that in mind
as a fallback if size pressure grows.)

## Changes (contract — `src/StableLPManager.sol`)

- Add `bytes32 private _name;` storage var.
- `struct InitParams { address owner; bytes32 name; PoolConfig[] pools; }` (insert `name`).
- In `initialize`: `_name = p.name;`.
- `name()` → `view`, decode `bytes32` → `string` (trim trailing zeros):
  ```solidity
  function name() public view override returns (string memory) {
      bytes32 n = _name;
      uint256 len;
      while (len < 32 && n[len] != 0) ++len;
      bytes memory b = new bytes(len);
      for (uint256 i; i < len; ++i) b[i] = n[i];
      return string(b);
  }
  ```
- (Factory `createManager` forwards the struct unchanged.)

## Call sites to update

- **Tests/helpers** that build `InitParams` (drop a `name`): `test/helpers/StableLPTestBase.sol:108`,
  `test/StableLPManagerNative.t.sol`, `test/StableLPManagerV2.t.sol`, `test/FeeRedeemer.t.sol`,
  `test/StableLPManagerAuditFixes.t.sol`. Pass e.g. `bytes32("Envelop StableLP")`.
- **Deploy scripts** that call `createManager`.
- **Frontend (`stablelp-ui`)**: `src/hooks/useCreateManager.ts` + `src/app/create/page.tsx` — add a
  name input (default "Envelop StableLP"), encode to `bytes32` (viem `stringToHex(name,{size:32})`),
  include in `InitParams`. Add a length guard (≤31 bytes). The card/page already read `name` from the
  descriptor's `tokenURI`, so display is covered once the chain value flows through.

## Verification

- `forge build --sizes` → StableLPManager ≤ 24,576 (expect ~24,233, ~343 B margin).
- `forge test` green (after updating the InitParams call sites).
- Frontend: create a manager with a custom name → `name()` returns it; NFT/descriptor metadata shows it.

## Notes

- ABI change to `InitParams` is breaking for any external caller of `createManager` — bump/redeploy
  factory+impl and re-sync ABIs (`stablelp-ui` `npm run sync-abi`) + `config/deployments.json`.
- Measured on a throwaway branch (`measure/init-name`, since deleted); numbers above are from that run.
