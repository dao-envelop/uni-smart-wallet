# UniSmartWallet Security Audit

**Date**: 2026-05-17
**Commit audited**: `master` HEAD `354c1ec`
**Scope**:
- `src/UniSmartWallet.sol` (main)
- `src/lib/PositionMath.sol`
- `src/interfaces/IHookRegistry.sol`
- `script/DeployWallet.s.sol`

**Out of scope**: `lib/envelop-protocol-v2/**`, `lib/v4-hooks-public/**`, OpenZeppelin under `lib/**`.

**Methodology**: 7 parallel Opus subagents per the `ethskills:audit` framework, each walking one specialist checklist from <https://github.com/austintgriffith/evm-audit-skills>. Slices loaded: `evm-audit-general`, `evm-audit-precision-math`, `evm-audit-defi-amm`, `evm-audit-erc20`, `evm-audit-erc721`, `evm-audit-access-control`, `evm-audit-dos`.

---

## Executive Summary

**Total findings: 8 High · 11 Medium · 14 Low · ~10 Info** (post-dedup; sub-agents raised 60+ individual items, several cross-flagged the same root cause).

The wallet is small (~500 lines of in-scope Solidity) and the core V4 settle/take/unlock plumbing is correctly wired. The risk concentrates in three places:

1. **Singleton-NFT-as-sole-authority** is a sharp design choice with sharp edges. The NFT is the only key to everything the wallet holds, has no two-step transfer, no approval-disabling override, and no recovery path — any of (typo, lost key, marketplace approval, transfer to a non-`onERC721Received` contract) permanently bricks the wallet.
2. **Hook trust surface is wider than the validator assumes.** `_isHookAllowed` keys on the 20-byte address only — it ignores the permission bits encoded in the V4 hook address. Combined with no mid-flight protection on `setHookAllowed`/`setHookRegistry`, an already-whitelisted hook can inflate slippage caps. (This item originally also claimed such a hook "can drive nested unlocks" via the missing `nonReentrant` on `unlockCallback` — **withdrawn**, see the [M-3] resolution: v4 reverts a nested `unlock`, and adding that modifier would brick every operation.)
3. **Asymmetric position lifecycle**: `_handleDecrease` does not clean up the registry when `liquidity` hits zero, and `closePosition`/`pokePosition` then revert on `UnknownPosition`. The inline comment that says "operator can call closePosition explicitly" describes an impossible path.

The recommended mitigations are: bounded operator set (or operator-epoch), two-step NFT handoff with `IERC721Receiver` check, slippage + deadline on close/decrease/poke, auto-cleanup of drained positions, hook-flag-mask validation, and a guardian-pause for `executeEncodedTx`. (`nonReentrant` on `unlockCallback` was on this list and is **withdrawn** — see the [M-3] resolution.) Most fixes are localized and small.

---

## Findings by Severity

### 🔴 High

#### [H-1] `_operatorList` grows unboundedly → NFT becomes non-transferable
**Severity**: High
**Category**: evm-audit-dos · evm-audit-erc721 · evm-audit-general · evm-audit-access-control (cross-flagged: D-1, N-1, G-1, AC-3)
**Location**: `UniSmartWallet.sol:133-146` (`setOperator`), `:162-172` (`_clearOperators`), `:150-160` (`_update`)

**Description**: `setOperator(op, true)` appends to `_operatorList` whenever `operators[op] == false`. The off branch (`setOperator(op, false)`) flips the mapping but never removes the array entry. Each on→off→on cycle for the same address appends a new entry; the list is append-only. `_clearOperators` iterates the full list on every NFT transfer (SLOAD + SSTORE + event per entry). After ~1–2k entries on mainnet, `transferFrom` reverts OOG. Because `_singletonMinted` blocks re-mint and `to == address(0)` blocks burn, **the NFT becomes permanently non-transferable** — the wallet's only ownership-handover mechanism is dead.

Naturally accreted via daily key rotation over months/years; deliberately achievable in minutes on any L2 by a malicious or about-to-depart owner.

**Recommendation**: Replace the list with a true set (swap-and-pop on disable, mirroring `_saltIndexPlusOne`), OR adopt an "operator epoch" pattern (`onlyAuthorized` compares `operatorEpochOf[op] == operatorEpoch`; transfer just bumps `operatorEpoch`). Cap operator count as defense in depth.

---

#### [H-2] Singleton NFT can be transferred to a brick-address without recovery
**Severity**: High
**Category**: evm-audit-erc721 · evm-audit-access-control (N-2, AC-1, AC-10)
**Location**: `UniSmartWallet.sol:150-160` (`_update`); inherited `ERC721.transferFrom`

**Description**: `_update` blocks `to == address(0)` (`SingletonBurnForbidden`) but accepts any other non-zero `to`. Concrete brick destinations:
- A precompile (`0x000…0001`–`0x000…000a`).
- A contract that implements `onERC721Received` but has no executor (e.g. random vault, staking contract, another `UniSmartWallet`).
- An EOA at a typo address with no key.
- `address(this)` (the wallet itself — sole authority becomes the wallet, no execution path).

Once the NFT lands at such an address, `onlyOwnerNFT` cannot be satisfied. `_clearOperators` ran on the transfer, so even operators can no longer act. All capital + open positions are stranded. There is no recovery: `_singletonMinted` blocks re-mint.

**Recommendation**: Implement two-step NFT handoff (`pendingOwner` + recipient-side `acceptOwnership()`). Reject `transferFrom`/`safeTransferFrom` for `TOKEN_ID` unless it's the post-accept path. Block `to == address(this)`. Optionally require `to.code.length == 0` OR `IERC165(to).supportsInterface(IERC721Receiver)`.

---

#### [H-3] OZ `approve` / `setApprovalForAll` over `TOKEN_ID` grants full wallet control
**Severity**: High
**Category**: evm-audit-erc721 (N-3)
**Location**: `UniSmartWallet.sol` — no override of `approve` / `setApprovalForAll`

**Description**: Since the NFT *is* the wallet authority, anyone with ERC-721 transfer rights can call `transferFrom` and become the wallet owner. The wallet inherits OZ ERC-721 verbatim — `setApprovalForAll(marketplace, true)` exposes the wallet to:
- Marketplace bug / operator compromise / wildcard-approval phishing.
- A user who lists the NFT on OpenSea/Blur for the *NFT's* market value (typically << the wallet's custodial value) implicitly puts all wallet assets on the line.

The two "operator" concepts in the contract (OZ `_operatorApprovals` vs the wallet's `operators` mapping) are distinct; `_clearOperators` clears the wallet's bot operators but does NOT clear OZ approvals.

**Recommendation**: Override `approve` and `setApprovalForAll` to revert (soulbound semantics). If marketplace listing is desired, route through a purpose-built escrow that atomically settles the sale + transfer in one tx, never via open-ended `setApprovalForAll`.

---

#### [H-4] Fee-on-transfer tokens brick `_handleOpen` and silently leak on `take`
**Severity**: High
**Category**: evm-audit-erc20 · evm-audit-defi-amm (E-1, AMM-3)
**Location**: `UniSmartWallet.sol:312-313` (settle), `:457-458` (take)

**Description**: `Currency.settle(POOL_MANAGER, address(this), owed, false)` pulls `owed` from the wallet to PoolManager via `transfer`. For fee-on-transfer / deflationary tokens (USDT on some chains, PAXG, STA, …) PoolManager receives `owed - fee` → settle invariant fails → entire `unlockCallback` reverts. Every `openPosition` against the pool DoS'd.

On the withdraw side `take` doesn't revert: wallet receives `owed - fee` but `PositionClosed` event records `owed` as principal, **silently leaking value and over-reporting** to off-chain accounting / Envelop oracle.

**Recommendation**: Document a currency allow-list / deny-list policy (V4 PoolManager is itself FoT-hostile). On the take side, measure `balanceOf(self)` delta and emit the actual received amount.

---

#### [H-5] USDC/USDT-style deny-list freezes the entire wallet
**Severity**: High
**Category**: evm-audit-erc20 (E-3)
**Location**: settle/take paths + `executeEncodedTx`

**Description**: Once a token admin adds `address(wallet)` to the deny-list:
- `take` reverts → cannot close any position in that currency.
- `executeEncodedTx(token, 0, IERC20.transfer.selector, …)` reverts → cannot withdraw wallet-held balance.
- Future `openPosition` reverts at settle.

The singleton NFT can be transferred to a fresh EOA, but **the wallet contract address is fixed** — no migration possible. Inherent custodial risk, but worth a documented mitigation.

**Recommendation**: Per-operator-risk-bucket isolation (separate wallet NFTs per regulated stablecoin); `emergencyAbandonPosition(bytes32 salt)` to prune `openSalts` for unrecoverable entries; document the censorship surface.

---

#### [H-6] Hook whitelist is permission-bit blind — a delta-returning hook is admitted by approving its address
**Severity**: High
**Category**: evm-audit-defi-amm (AMM-1)
**Location**: `_isHookAllowed`, `setHookAllowed`, `openPosition` (validation step 3)

**Description**: V4 hook permissions are encoded in the low bits of the address. `_isHookAllowed` only checks `allowedHooks[hook]` keyed by the full 20-byte address — it never inspects which permission flags are active. Therefore:
- Owner intends to whitelist a benign analytics hook; H's address happens to have `BEFORE_ADD_LIQUIDITY_RETURNS_DELTA_FLAG` set. PoolManager routes `_handleOpen`'s `modifyLiquidity` through delta-returning hook code.
- A `*_RETURNS_DELTA` hook can return a `BalanceDelta` that inflates the wallet's owed amount up to `amount0Max` / `amount1Max` — turning the slippage cap into the *target* a malicious hook will tax up to (compounds with H-7 / H-8).

**Recommendation**: Store and validate an expected permission-flag mask per hook: `mapping(address => uint16) allowedHookFlags;` plus `require(uint160(hook) & Hooks.ALL_HOOK_MASK == expectedFlags)`. At minimum reject any hook whose address has any `*_RETURNS_DELTA` bit set unless explicitly opted in.

---

#### [H-7] Owner can sandwich an in-flight `openPosition` by flipping hook policy mid-tx
**Severity**: High
**Category**: evm-audit-defi-amm · evm-audit-access-control (AMM-2, AC-4)
**Location**: `setHookAllowed`, `setHookRegistry`, `setOperator` (all owner-only, no timelock, no in-flight protection)

**Description**: `setHookAllowed`/`setHookRegistry`/`setOperator` mutate authorization state instantly with no timelock and are NOT `nonReentrant`. An owner with mempool control can sandwich an operator's `openPosition` with `[setHookAllowed(H, true), operator.openPosition(key.hooks=H), setHookAllowed(H, false)]` — the operator believed H was disallowed at submission time. The Dacian CLM "ineffective TWAP" pattern without the TWAP gate.

A compromised owner key can chain in a single tx: `setHookAllowed(maliciousHook, true)` + `setOperator(attacker, true)` + (attacker submits `openPosition` using the malicious hook). No `executeEncodedTx` needed for the drain.

**Recommendation**: Bind hook decision through the unlock payload (re-validate inside `_handleOpen` against `keccak(hook, flags)`). Add a delay on enabling (`false → true`); keep revocation instant. Add `nonReentrant` to setters and `executeEncodedTx`.

---

#### [H-8] No slippage / deadline on `closePosition` / `decreasePosition` / `pokePosition`
**Severity**: High
**Category**: evm-audit-defi-amm (AMM-4)
**Location**: `closePosition`, `decreasePosition`, `pokePosition`, `_withdrawLiquidity`

**Description**: All three exit-side primitives encode `RemoveParams{key, tickLower, tickUpper, deltaLiquidity, salt}` with NO `amount0Min`, `amount1Min`, or `deadline`. Whatever PoolManager returns is `take`d. Canonical sandwich vector for concentrated LP removal: attacker swaps to push the price below `tickLower` → position becomes 100% currency0 → front-run operator's `closePosition` → swap back. Wallet eats the spread.

Worse than the equivalent vector on `openPosition` (which DOES have `amount0Max`/`amount1Max`) because:
- **Operators**, not just the owner, can call these — a hot-bot key compromise is sufficient.
- `closePosition` is the only exit; there is no slippage-protected alternative.

**Recommendation**: Add `uint128 amount0Min, uint128 amount1Min, uint256 deadline` to `closePosition` and `decreasePosition`. For `pokePosition`: `minFees0`, `minFees1`. Enforce in `_withdrawLiquidity` / handlers.

---

### 🟠 Medium

#### [M-1] `decreasePosition` to zero liquidity strands the salt; `closePosition` recovery is impossible
**Severity**: Medium
**Category**: evm-audit-general · evm-audit-defi-amm (G-2, AMM-7)
**Location**: `_handleDecrease` (`UniSmartWallet.sol:409-419`), `closePosition` (`:339-357`)

**Description**: `_handleDecrease` subtracts `r.deltaLiquidity` from `positions[r.salt].liquidity` but does not clean up `openSalts` / `_saltIndexPlusOne` / `positions` when `liquidity` hits 0. The inline comment at `:414-415` says "operator can call `closePosition` explicitly if they want the registry entry cleared" — but `closePosition` begins with `if (p.liquidity == 0) revert UnknownPosition(salt);`. The path doesn't exist. The salt is permanently unreachable via every position function, `openSalts` accumulates dead entries, and any fees that accrue between decrease and re-open are unclaimable.

**Recommendation**: In `_handleDecrease`, branch on post-decrement liquidity:
```solidity
uint128 newLiq = positions[r.salt].liquidity - r.deltaLiquidity;
if (newLiq == 0) { _removeSalt(r.salt); delete positions[r.salt]; }
else { positions[r.salt].liquidity = newLiq; }
```
Drop the misleading comment.

---

#### [M-2] Re-opening a drained salt corrupts `openSalts` (ghost entries accumulate)
**Severity**: Medium
**Category**: evm-audit-general (G-3)
**Location**: `openPosition`, `_handleOpen`, `_removeSalt`

**Description**: Combined with M-1. The salt-collision guard `if (positions[salt].liquidity != 0)` no longer protects the registry once a salt has been drained via decrease. A re-`openPosition` with the same salt passes the check, pushes a new `openSalts` entry, and overwrites `_saltIndexPlusOne[salt]`. The previous stale entry in `openSalts` is never removed — `_removeSalt` on the later close only pops the latest index. Every drain→reopen cycle strictly grows ghost-entry count; `openPositionCount()` reports a number larger than reality.

**Recommendation**: Fix M-1 (clean up on drain); as defense-in-depth, in `_handleOpen` reject salts where `_saltIndexPlusOne[salt] != 0`, not just `positions[salt].liquidity != 0`.

---

#### [M-3] Nested `unlockCallback` re-entry via malicious hook bypasses `nonReentrant`
**Severity**: Medium
**Category**: evm-audit-defi-amm (AMM-6)
**Location**: `unlockCallback`

**Description**: `nonReentrant` is on `openPosition`/`closePosition`/`decreasePosition`/`pokePosition` only. `unlockCallback` itself is NOT `nonReentrant`. PoolManager allows nested `unlock()`. A hook invoked during the outer unlock can call `POOL_MANAGER.unlock(maliciousPayload)`, which causes PoolManager to call back into `wallet.unlockCallback(...)` — `msg.sender == POOL_MANAGER` is still true, the gate passes, and the dispatcher executes the attacker-chosen op on attacker-chosen state mid-flight (e.g., closing a victim salt while opening another).

**Recommendation**: Add `nonReentrant` to `unlockCallback`. Additionally, set an `_inflightOp` flag in the outer entrypoint and require the callback payload to match it — bind dispatch to the outer caller.

> ### RESOLUTION 2026-07-30 (task_044): NOT APPLICABLE — and **do not apply the recommendation**
>
> The finding rests on "PoolManager allows nested `unlock()`". That is **false** for the v4-core this
> repo compiles against (`lib/v4-hooks-public/lib/v4-core`, pin `d153b048`, `git describe` `v4.0.0-19`;
> `remappings.txt` confirms it is the tree actually built). `PoolManager.sol:102-114`:
>
> ```solidity
> function unlock(bytes calldata data) external override returns (bytes memory result) {
>     if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();   // ← first statement
>     Lock.unlock();
>     result = IUnlockCallback(msg.sender).unlockCallback(data);
>     if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
>     Lock.lock();
> }
> ```
>
> `Lock` is a transient global boolean (`tstore`/`tload`, no depth counter), set before the callback and
> cleared only after it returns, so for the whole duration of any `unlockCallback` a second `unlock()` is
> uncallable by anyone. Three independent barriers, each sufficient alone:
>
> 1. **`AlreadyUnlocked`** — a nested `unlock()` anywhere in the call tree reverts.
> 2. **`IUnlockCallback(msg.sender)`** — the callback target is hardcoded to the caller; `unlock` takes no
>    address, so no third party can be named. A hook that calls `unlock` receives *its own* callback, not
>    the manager's. `PoolManager.sol:110` is the only non-test invocation of `unlockCallback` in v4-core.
> 3. **`NotPoolManager`** — a forged direct call to `manager.unlockCallback(data)` is rejected at the door.
>
> The "attacker-chosen op on attacker-chosen state" half has no input path either: every one of the 8
> `POOL_MANAGER.unlock` call sites builds `abi.encode(CONSTANT_OP, abi.encode(...))` where the op is a
> compile-time constant chosen by the entry point and never read from calldata, and `byOwner` is computed
> on-chain via `_isOwnerCall()`.
>
> **The recommendation must NOT be applied.** OZ `ReentrancyGuard` is one shared `_status` slot per
> contract (`ReentrancyGuard.sol:50-51,94-99`), and every function that reaches `unlock` already holds
> `nonReentrant` (`allocate`, `allocateFrom`, `reinvest`, `claimFees` in both products, `recenter`,
> `withdrawTo`). `unlockCallback` is therefore entered with `_status == ENTERED` **by construction**, so
> the modifier reverts `ReentrancyGuardReentrantCall` on every operation. Verified by applying it
> temporarily: `test/VolatileLPManagerAllocate.t.sol` went to **0 passed, 6 failed**, each
> `ReentrancyGuardReentrantCall()`. The `_inflightOp` half has nothing to bind against, the op being ours
> rather than the caller's.
>
> Residual, for the record: the reachable re-entrancy shape is external code invoked mid-unlock (a hook,
> an ERC-777-style token in `_settle`/`_take`, a `withdrawTo` recipient) calling back into a *different*
> entry point — closed by that same shared `nonReentrant` on all of them. The one unguarded entry point
> is `executeEncodedTxBatch`, which is **[M-4]** below and still open.
>
> Note also that the locations named above (`openPosition` / `closePosition` / `decreasePosition` /
> `pokePosition`) belonged to `UniSmartWallet`, removed in task_025; the live dispatcher is
> `BaseLPManager.unlockCallback` → `_dispatchExtraOp`.

---

#### [M-4] No `nonReentrant` on `executeEncodedTx` — ERC-777/677 callback can re-enter via contract owners
**Severity**: Medium
**Category**: evm-audit-erc20 (E-8)
**Location**: `executeEncodedTx`, `executeEncodedTxBatch`

**Description**: Position ops are `nonReentrant`; execute primitives are not. An ERC-777 callback fires during a `transfer` initiated by `executeEncodedTx` — if the NFT owner is a contract that proxies the callback back to the wallet, `msg.sender == ownerOf(TOKEN_ID)` holds and re-entry succeeds, interleaving arbitrary calls. EOA owners are unaffected (no callback path); contract owners (multisigs, smart-wallet wrappers) are exposed.

**Recommendation**: Add `nonReentrant` to `executeEncodedTx` and `executeEncodedTxBatch`. Trivial gas cost; meaningful hardening for non-EOA owners.

---

#### [M-5] Rebasing tokens cause silent value drift in PoolManager-held positions
**Severity**: Medium
**Category**: evm-audit-erc20 (E-2)
**Location**: `_handleOpen`, `_withdrawLiquidity`

**Description**: PoolManager denominates position-backing balances in absolute units and does not subscribe to rebase events. Positive-rebase tokens (stETH) leave the yield as arbitrage profit for swappers (wallet's economic share is unchanged but the upside is lost); negative-rebase tokens (AMPL contracting) leave PoolManager under-collateralised — `take` later reverts.

**Recommendation**: Disallow rebasing tokens by policy (document). Same applies to centralized stablecoins with admin force-burn.

---

#### [M-6] No emergency pause / freeze
**Severity**: Medium
**Category**: evm-audit-access-control (AC-5)
**Location**: contract-wide

**Description**: There is no `Pausable` switch on `executeEncodedTx`, `openPosition`, or setters. If a critical bug surfaces in a whitelisted hook, the owner can react only by closing positions one-by-one. No way to atomically freeze new opens while guardian closes existing ones in parallel.

**Recommendation**: Add `paused` flag with `whenNotPaused` on `openPosition` (and optionally `executeEncodedTx`). `pause()` callable by NFT owner *and* a pre-registered `guardian`. `unpause()` only by owner. Pause must never block `closePosition`/`decreasePosition`/`pokePosition` so users can always exit.

---

#### [M-7] Hook policy mutable mid-flight — owner can grief operator strategies
**Severity**: Medium
**Category**: evm-audit-access-control (AC-6)
**Location**: `setHookAllowed`, position ops

**Description**: `_isHookAllowed` is consulted on `openPosition` but NOT on the exit primitives (correct — funds must always be extractable). Owner mid-flight `setHookAllowed(H, false)` between operator's intent submission and inclusion grieves operator strategies that depended on H. Conversely, AC-4 / H-7 covers the malicious-grant direction.

**Recommendation**: Snapshot the hook decision in the `Position` struct at open time so consumers can verify the policy in force when a position was opened. Document that hook-policy changes affect only future opens.

---

#### [M-8] Operator trust model is implicit — operator can front-run owner with salt collision
**Severity**: Medium
**Category**: evm-audit-access-control (AC-7)
**Location**: `onlyAuthorized` / `setOperator` / `openPosition`

**Description**: An operator is a single boolean. No per-pool restriction, no notional cap, no per-day rate limit, no per-operator hook allowlist. Operators can also **front-run owner intent**: an operator who learns the owner is about to call `openPosition(pool=P, salt=S, ...)` can submit it first with adversarial `amount0Max`/`amount1Max`. The owner's later tx reverts on `SaltCollision(S)`; the operator now controls the position on operator terms.

**Recommendation**: Scoped operator policy: `mapping(address => OperatorPolicy)` with max notional, allowed pool IDs / hooks, expiry timestamp. If keeping the boolean, document the "operators are fully trusted bots" assumption in NatSpec and external docs.

---

#### [M-9] Deploy script permanently loses wallet on misconfigured `initialOwner`
**Severity**: Medium
**Category**: evm-audit-access-control · evm-audit-general (AC-9, G-7)
**Location**: `script/DeployWallet.s.sol:42-95`

**Description**: `deployAndAssign` reads `initialOwner` from `chain_params.json` and calls `wallet.transferFrom(currentHolder, initialOwner, TOKEN_ID)`. Validation: `initialOwner != 0` only. No two-step accept (see H-2), no `safeTransferFrom` receiver check, no post-condition that the recipient can act. A typo or stale config in the JSON permanently bricks every wallet deployed under it — visible only when someone later tries `executeEncodedTx`.

**Recommendation**: Couple with the H-2 two-step pattern: script *proposes*, recipient *accepts* with a separate tx. Defense-in-depth: prefer `safeTransferFrom` and revert if `wallet.ownerNFTHolder() != initialOwner` at end of `run()`.

---

#### [M-10] V4 native ↔ ERC-20 wrapper aliasing (Celo, POL, zkSync ETH)
**Severity**: Medium
**Category**: evm-audit-erc20 (E-16)
**Location**: settle/take paths

**Description**: V4 `Currency` uses `address(0)` as the native-ETH sentinel. On Celo / Polygon / zkSync the native asset is *also* exposed as an ERC-20 at a fixed address. The wallet has no deduplication — an operator can open positions on both `currency=address(0)` and `currency=ERC20-of-native`, same economic asset, treated as distinct. **Was a real V4 vulnerability on Celo**. The wallet inherits this surface.

**Recommendation**: Document a per-chain `Currency` allowlist that excludes the ERC-20 wrapper of native on those chains; or refuse opens on the affected chains until a hardened version is shipped.

---

#### [M-11] `unlockCallback` discards `feesAccrued` on open — delta-returning hooks brick opens
**Severity**: Medium
**Category**: evm-audit-defi-amm (AMM-18)
**Location**: `_handleOpen` line 292

**Description**: `(BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(...)` discards the second return. For hooks with `AFTER_ADD_LIQUIDITY_RETURNS_DELTA`, `feesAccrued` on `+L` can be non-zero. The unsettled portion fails PoolManager's `NonzeroDeltaCount` invariant at unlock close → revert. Every open against such a hook fails. No fund loss, but a liveness issue for legitimate hooks.

**Recommendation**: Read both return values and settle `delta + feesAccrued` (V4 `BalanceDelta.add`).

---

### 🟡 Low

#### [L-1] Returndata bombing via `executeEncodedTx{,Batch}` (D-2)
Owner-only footgun. `Address.functionCallWithValue` (used by parent `_executeEncodedTx`) copies full returndata. A malicious target returning megabytes triggers quadratic memory-expansion gas in the wallet frame. In `executeEncodedTxBatch`, one bomb-return element OOGs the whole batch even when prior calls were cheap.
**Fix**: Inline-assembly low-level call that ignores returndata on success and caps on revert; per-element returndata cap in batch.

#### [L-2] `uint256(uint128(-d0))` reverts when `d0 == type(int128).min` (PM-1)
On `_handleOpen` line 306-307. Honest pools never produce `int128.min` but the pattern is fragile.
**Fix**: `uint256 owed0 = d0 < 0 ? uint256(-int256(d0)) : 0;`

#### [L-3] `snapTickLower`/`snapTickUpper` can overflow `int24` near type bounds (PM-2)
Latent — UniSmartWallet itself doesn't use these helpers (only `requireValidTickRange`). Affects any future caller that hasn't pre-clamped to `[minUsableTick, maxUsableTick]`.
**Fix**: Compute the multiplication in `int256` and clamp before returning, or document the precondition + revert explicitly.

#### [L-4] `owed - fees` underflow if hook reports `fees > owed` (PM-4, AMM-10)
`_handleClose` line 405, `_handleDecrease` line 417. Solidity 0.8 checked subtraction reverts the whole withdraw, even though the `take()` already succeeded.
**Fix**: Saturate — `uint256 principal0 = owed0 > fees0 ? owed0 - fees0 : 0;`

#### [L-5] Negative `delta`/`feesAccrued` from hook silently zeroed (PM-5)
`_withdrawLiquidity` only handles non-negative. Negative delta (e.g. exit-fee hook) is muted; PoolManager unlock then reverts on unsettled debit. Far-from-source failure mode.
**Fix**: Either symmetrically settle the negative branch (mirroring `_handleOpen`), or revert with a typed error.

#### [L-6] `setHookAllowed(address(0), false)` disables all hookless pools (G-4)
Owner-only footgun; no input validation. Recoverable but surprising.
**Fix**: `setHookAllowed`: `require(hook != address(0) || allowed)`. `setHookRegistry`: probe via `IHookRegistry(registry).isAllowed(address(0))` in try/catch to fail fast on ABI mismatch.

#### [L-7] `nonReentrant` modifier order — guard applied after `onlyAuthorized` (G-5)
Lint violation only; `onlyAuthorized` is SLOAD-only today. Future-proofing.
**Fix**: Re-order to `external nonReentrant onlyAuthorized`.

#### [L-8] `pragma ^0.8.20` emits PUSH0 — breaks deployment on non-Shanghai chains (G-6)
Multi-chain deploy script reads `chain_params.json` for chains some of which historically lacked PUSH0 (e.g. zkSync pre-Shanghai). Set Foundry `evm_version = paris` (or pin per chain).

#### [L-9] Deploy script uses `transferFrom` not `safeTransferFrom` (G-7)
Compounds H-2. `initialOwner` contract without `onERC721Received` silently bricks the wallet.
**Fix**: `safeTransferFrom`; or `IERC165(initialOwner).supportsInterface(IERC721Receiver)` pre-check.

#### [L-10] `_singletonMinted` flag-based check vs `_ownerOf(TOKEN_ID)` check (N-4)
Not exploitable in current code. Inherited subclasses could `sstore(_singletonMinted.slot, 0)` to bypass.
**Fix**: Replace with `if (_ownerOf(TOKEN_ID) != address(0)) revert SingletonAlreadyMinted();`. Document the contract is not intended to be inherited from.

#### [L-11] `_baseURI` not overridden — `tokenURI(1)` returns `""` despite the public `DEFAULT_BASE_URI` constant (N-6)
UX bug + amplifies H-3 mis-valuation risk on marketplaces.
**Fix**: Override `_baseURI()`; or override `tokenURI` to include `address(this)` so per-wallet metadata is distinct.

#### [L-12] EIP-4906 `MetadataUpdate` emitted but interface not advertised (N-7)
`supportsInterface` doesn't return true for `IERC4906`. Indexers can't subscribe.
**Fix**: Add `|| interfaceId == 0x49064906`, or drop the constructor `MetadataUpdate` emission (it never fires again — no setter exists).

#### [L-13] USDT approve race via `executeEncodedTx` (E-4)
USDT `approve` reverts when `current > 0 && new > 0`. Owner footgun; document or batch reset.

#### [L-14] Pausable currencies brick open/close until unpause (E-9)
Inherent to holding pausable assets. Document.

---

### ℹ️ Info

- **[I-1]** `Position.openedAt` truncated to `uint64` (G-8) — overflow in ~584 billion years; benign.
- **[I-2]** `requireValidTickRange` doesn't validate `spacing > 0` — opaque panic 0x12 if ever passed (PM-3). Defensive only; v4 itself rejects `tickSpacing <= 0` at `initialize`.
- **[I-3]** No `SafeERC20.safeTransfer` convenience helper for owner withdrawals (E-5). Owner must hand-craft calldata; USDT-on-Ethereum no-return-value tokens require care.
- **[I-4]** Operator-management events fire even on state-no-change; ordering of `Transfer` vs `OperatorSet(false)` is brittle for downstream consumers (AC-8). No security impact.
- **[I-5]** No sweep path for ERC-6909 claim tokens or stale ERC-20 dust (AMM-9). Hook can `manager.mint(address(this), id, x)`; wallet has no API to spend. `executeEncodedTx` covers ERC-20 escape but ERC-6909 needs precise PoolManager calldata.
- **[I-6]** `_isHookAllowed` calls external registry with no try/catch (AMM-11). A broken/malicious registry bricks every open. Wrap in try/catch and fail closed.
- **[I-7]** Operator can route the wallet into an attacker-initialized pool (AMM-12). V4 lets anyone `initialize` a pool with chosen `sqrtPriceX96`. Mitigation: non-zero `minPoolLiquidity` floor + per-PoolId allowlist.
- **[I-8]** Strict `>` slippage check in `_handleOpen` allows hooks to hit the cap exactly (AMM-8). Combined with H-6.
- **[I-9]** V4 has no native pause; hooks can simulate one (AMM-14). Operator UX concern.
- **[I-10]** No FoT/decimal-aware paths anywhere — wallet is decimal-agnostic by design (E-13). Correct.

---

## Cross-cutting themes

### Singleton-NFT authority surface
H-1, H-2, H-3, M-9, L-9, L-10, L-11, L-12 all stem from the same architectural choice. A bounded set of changes hardens it dramatically:
1. Override `approve` + `setApprovalForAll` to revert.
2. Two-step transfer with recipient `acceptOwnership`.
3. `operatorEpoch` instead of iteration on transfer.
4. `safeTransferFrom` in deploy script + receiver-interface check.
5. Block `to == address(this)` and the precompile range in `_update`.

### Hook trust gap
H-6, H-7, M-11, I-6, I-7 cluster on hook validation (M-3 was listed here and is **withdrawn** — it was
not a hook-validation issue and not reachable at all; see its resolution block):
1. Validate hook permission flags via address mask.
2. ~~`nonReentrant` on `unlockCallback` + outer-op binding.~~ Withdrawn — would brick every operation.
3. Snapshot hook decision at open, never re-trust unless re-validated.
4. Read `feesAccrued` on open path and settle it.
5. try/catch around `IHookRegistry`.

### Position lifecycle asymmetry
M-1 + M-2 are one bug. Fix in `_handleDecrease`: auto-clean registry when post-decrement liquidity is zero.

### Exit-path hygiene
H-8 + L-4 + L-5: add `amount0Min`/`amount1Min`/`deadline` to close/decrease/poke; saturate or symmetrically handle delta/fee signs.

---

## Issue filing

`evm-audit-master` SKILL recommends filing GitHub issues for Medium+ findings. **This repository is hosted on GitLab** (`gitlab.com/envelop/protocol-v2/uniswap-smart-wallet`), so `gh issue create` does not apply. Recommended alternatives:
- Use `glab issue create` if the project has `glab` CLI integration set up.
- Or file MRs that fix the bugs directly, one per finding (smaller MRs are easier to review).
- Or open a single tracking issue manually on GitLab referencing this report.

Ready to file any subset on your signal.
