# Security Audit — UniSmartWallet / StableLPManager (Uniswap V4)

**Scope:** `src/StableLPManager.sol`, `src/abstract/V4PositionManager.sol`,
`src/abstract/SingletonNFTOwned.sol`, `src/UniSmartWallet.sol`, `src/StableLPFactory.sol`,
`src/WalletPositionDescriptor.sol`, `src/lib/PositionState.sol`, `src/lib/PositionMath.sol`.
**Method:** 8 parallel domain agents (general, precision-math, defi-amm, erc20, erc721, access-control,
dos, proxies) against the [evm-audit-skills](https://github.com/austintgriffith/evm-audit-skills)
checklists, then dedup + synthesis. Branch `task-015-protocol-fee`.

**Verdict:** No critical or externally-exploitable fund-drain. One HIGH (protocol-fee treasury blocklist)
was found and **fixed** during the review. Remaining items are LOW/INFO; the substantive LOWs are fixed,
the rest documented/accepted.

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | HIGH | Protocol-fee ERC-20 skim to an immutable treasury → a stablecoin blocklist/pause on the treasury reverts the only liquidity-exit path (`withdrawTo`) and permanently locks LP principal | **FIXED** — skim as ERC-6909 claims (`_takeClaim`); treasury redeems later |
| 2 | MEDIUM | `withdrawTo` swaps / `_addLiquidity` size against live `getSlot0`; protection is operator-supplied `sqrtPriceLimitX96`/`minLiquidity`/caps (MEV/sandwich if loose). Owner/operator-gated, not external | DOCUMENTED — each swap is already price-bounded by `sqrtPriceLimitX96`; operator must set it tight |
| 3 | LOW | `_operatorList` never pruned on `setOperator(op,false)`; re-enable churn grows it unboundedly → `_clearOperators` on NFT transfer can OOG and brick the auth handover | **FIXED** — splice-on-disable (1-based index map) |
| 4 | LOW | Protocol fee rounded DOWN (`fee*1000/10000`); sub-threshold accruals skim 0 — bias against the protocol | **FIXED** — round up (inline ceil) |
| 5 | LOW | `StableLPManager._addLiquidity` lacked the `sqrtPrice==0` uninitialized-pool guard the base `_openPosition` has | **FIXED** — `revert PoolUninitialized` added |
| 6 | LOW | auto-`allocate` has no aggregate spend cap — an operator can deploy the manager's entire idle balance (recoverable; not theft) | DOCUMENTED — by design (operator-trusted) |
| 7 | LOW/INFO | Fee-on-transfer / rebasing tokens break `_settle` / `allocateFrom` snapshot / `withdrawTo` delivery (assume `received==sent`) | DOCUMENTED — managed currencies must be standard ERC-20 |
| 8 | INFO | No deadlines; `tokenURI` unbounded for the multi-position wallet (view only); `executeEncodedTx*` not `nonReentrant` (owner-only); out-of-band clone init (factory is atomic); no two-step NFT handoff; `reinvestRemainder` is a no-op | ACCEPTED / documented |

## Confirmed correct (positives)
- `unlockCallback` gated to `POOL_MANAGER`; all deltas net via `_settleManaged` (no `CurrencyNotSettled`).
- Singleton-NFT invariant (mint-once, no-burn, operator auto-clear); clone atomic init + impl lockout;
  immutables read correctly through clones; OZ v5 `ReentrancyGuard` is clone-safe (namespaced, zero-default).
- int128↔uint256 abs-casts, Q128 fee-growth wrap math, exactIn/exactOut swap-delta signs all correct.
- USDT missing-return tolerated (v4 settle = balance-delta; take = Solady assembly). No selfdestruct/delegatecall.
- The #15 protocol fee is **unavoidable** (skimmed at every fee-realizing `modifyLiquidity`) and principal
  is never taxed.

## Remediation
Findings 1, 3, 4, 5 fixed in code with regression tests (`StableLPManagerProtocolFee.t.sol`,
`StableLPManagerAuditFixes.t.sol`). See `tasks/task_015_protocol_fee.md` (HIGH fix) and
`tasks/task_016_audit_remediation.md` (LOW fixes). 118 tests pass, 1 fork test skipped without `BASE_RPC`.

> Note: after remediation `StableLPManager` is ~24,399 bytes — **EIP-170 margin ~177 B**. Any further
> growth needs a size lever (lower `optimizer_runs`, or extract allocate/withdraw into a delegatecall library).
