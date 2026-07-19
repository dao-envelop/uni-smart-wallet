# Task 036 — BaseLPManager: envelop-protocol-v2 event-model compatibility

Aligns the managers' event model with envelop-protocol-v2 (`lib/envelop-protocol-v2/src/impl/SmartWallet.sol`,
`WNFTV2Envelop721.sol`).

## Changes

### 1. `EnvelopV2OracleType` → implementation constructor
Moved `emit EnvelopV2OracleType(ORACLE_TYPE(), _productName())` from `BaseLPManager._finishInit` (per-clone)
to the `BaseLPManager` constructor (per-implementation), mirroring envelop's `WNFTV2Envelop721:111`. The
oracle type is a property of the logic contract, declared once at impl deploy (Stable 3000 / Volatile 3001).
`ORACLE_TYPE()` / `_productName()` are `pure` overrides, dispatched to the concrete product from the base
constructor. `EnvelopWrappedV2` / `Initialized` stay in `_finishInit` (per-clone). Per-clone consumers get
the oracle type from the factory's `EnvelopV2Deployment` event (task_035).

### 2. `SmartWallet` ether-tracking pattern (copied, not inherited)
Managers are ERC20-only (no ERC721/1155 custody), so we copy the pattern rather than inherit `SmartWallet`:
- `event EtherReceived(...)` emitted in `receive()` (now `virtual`).
- `event EtherBalanceChanged(...)` + `modifier fixEtherBalance` + `_fixEtherChanges` (emits only when the
  balance moved) + `_emitWrapper`.
- `fixEtherBalance` applied to **every value-moving external entry point** (native-ETH pools move ether via
  `settle{value}`/`take`; the escape hatch sends native): base `withdrawTo` / `executeEncodedTxBatch`;
  Stable `allocate` / `allocateFrom` / `reinvest` / `claimFees`; Volatile `allocate` / `recenter` /
  `claimFees`. Non-value functions (`setOperator` / `setPositionDescriptor` / `setPriceOracle` /
  `initialize`) are untouched.

EIP-170: `StableLPManager` 23,911 B (665 B margin) — full scope fits; the constructor-move even reclaims a
little runtime bytecode.

## Tests
`test/EnvelopEventModel.t.sol` — `EnvelopV2OracleType` emitted in each product's impl constructor (3000 /
3001); `EtherReceived` on `receive()`; `EtherBalanceChanged` around `executeEncodedTxBatch{value}`; no
`EtherBalanceChanged` on an ERC20-only op (bb == ba guard). No existing test asserts these events.

## Verification
```bash
forge fmt --check
forge build --sizes    # StableLPManager < 24576 B
forge test -vvv
```
</content>
