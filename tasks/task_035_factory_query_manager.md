# Task 035 — LPManagerFactory: query the manager instead of hard-coding; Envelop deployment event

Cleanup on `src/LPManagerFactory.sol` (post-#33). The manager is the single source of truth — stop
hard-coding values the manager already exposes.

## Changes
1. **De-hardcode `TOKEN_ID`.** Removed the factory's `uint256 private constant TOKEN_ID = 1`. The post-init
   owner check now queries the manager: `m.ownerOf(m.TOKEN_ID())` via a minimal `IEnvelopManager` view
   interface. Same behavior (`TOKEN_ID()` is the manager's public constant; `ownerOf` reverts if nothing
   was minted).
2. **De-hardcode oracle type + new event.** Replaced `event ManagerCreated(manager, implementation, owner,
   nonce)` with **`event EnvelopV2Deployment(address indexed proxy, address indexed implementation,
   uint256 envelopOracleType)`**, where `envelopOracleType` is queried from the manager's `ORACLE_TYPE()`
   (Stable 3000 / Volatile 3001). Aligns factory deployments with Envelop-ecosystem indexing. `_initAndFund`
   no longer needs the nonce/sentinel parameter. `ManagerFunded` (native-funding event) is unchanged.

Interface added at file scope:
```solidity
interface IEnvelopManager {
    function TOKEN_ID() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function ORACLE_TYPE() external view returns (uint256);
}
```
`IERC721` import dropped (no longer used).

**Breaking:** off-chain indexers keying on `ManagerCreated` must switch to `EnvelopV2Deployment` (event ABI
changed; owner/nonce dropped from the event — owner remains verifiable via `ownerOf`).

## Tests
- `test/LPManagerFactoryCreate.t.sol` — new `test_emitsEnvelopV2Deployment_withQueriedOracleType` asserts
  the event carries the manager-queried oracle type (Stable 3000). Existing `ownerMismatch` / `initFailed`
  tests continue to exercise the query-based owner check.

## Verification
```bash
forge fmt --check
forge build --sizes
forge test --match-path "test/LPManagerFactory*.t.sol" -vvv
forge test
```
</content>
