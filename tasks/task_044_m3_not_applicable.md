# task_044 — [M-3] is not applicable to the pinned v4, and its fix would brick the contract

Documentation and comments only. **Zero bytecode change** — verified: Stable 24,094 / Volatile 23,718 /
Open 23,658, unchanged; 222 tests pass; `forge fmt --check` clean.

## What prompted it

While closing out task_043 I wrote, in three places, that audit `2026-05-17` [M-3] was still open and that
the hookless gate was what closed its hook-borne variant. Asked to explain the actual risk, I went to
verify the mechanism and found the finding's premise does not hold.

## The finding's premise is false for our v4

[M-3] (`audits/2026-05-17/AUDIT-REPORT.md:185`) rests on one sentence: *"PoolManager allows nested
`unlock()`."* Against `lib/v4-hooks-public/lib/v4-core` (pin `d153b048`, `git describe` `v4.0.0-19`,
submodule clean, and `remappings.txt` confirms it is the tree actually compiled), `PoolManager.sol:102-114`:

```solidity
function unlock(bytes calldata data) external override returns (bytes memory result) {
    if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();   // ← first statement
    Lock.unlock();
    result = IUnlockCallback(msg.sender).unlockCallback(data);
    if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
    Lock.lock();
}
```

`Lock` is a transient global boolean (`tstore`/`tload`, no depth counter) set before the callback and
cleared only after it returns, so for the whole duration of any `unlockCallback` a second `unlock()` is
uncallable by anyone. Three independent barriers, each sufficient on its own:

1. **`AlreadyUnlocked`** — a nested `unlock()` anywhere in the call tree reverts.
2. **`IUnlockCallback(msg.sender)`** — the callback target is hardcoded to the caller; `unlock` takes no
   address argument, so no third party can be named. A hook that calls `unlock` receives *its own*
   callback. `PoolManager.sol:110` is the only non-test invocation of `unlockCallback` in all of v4-core.
3. **`NotPoolManager`** — a forged direct call to `manager.unlockCallback(data)` is rejected at the door.

The "attacker-chosen op on attacker-chosen state" half has no input path either: all 8
`POOL_MANAGER.unlock` sites build `abi.encode(CONSTANT_OP, abi.encode(...))` with the op a compile-time
constant chosen by the entry point and never read from calldata; `byOwner` is computed on-chain via
`_isOwnerCall()`.

## The recommended fix would brick every operation — demonstrated, not argued

OZ `ReentrancyGuard` is one shared `_status` slot per contract (`ReentrancyGuard.sol:50-51,94-99`), and
every function that reaches `unlock` already holds `nonReentrant`: `allocate`, `allocateFrom`, `reinvest`,
`claimFees` (both products), `recenter`, `withdrawTo`. So `unlockCallback` is entered with
`_status == ENTERED` **by construction**.

Rather than assert that, I applied the recommendation temporarily and ran the suite:

```
[FAIL: ReentrancyGuardReentrantCall()] test_allocate_opensPosition()
[FAIL: ReentrancyGuardReentrantCall()] test_allocate_multiPositionPerPool()
[FAIL: ReentrancyGuardReentrantCall()] test_allocate_rangeMismatch_reverts()
...
Suite result: FAILED. 0 passed; 6 failed; 0 skipped
```

Then reverted (`git diff` empty, suite back to 14/14). The `_inflightOp` half of the recommendation has
nothing to bind against, the op being ours rather than the caller's.

This is the reason the finding needed an explicit resolution instead of being left open: as written it
invites a "fix" that is strictly worse than the non-existent bug it targets.

## What is actually left

The reachable re-entrancy shape is external code invoked mid-unlock — a hook, an ERC-777-style token in
`_settle`/`_take`, a `withdrawTo` recipient — calling back into a *different* entry point. That is closed
by the same shared `nonReentrant` on all of them. The one unguarded entry point is
`executeEncodedTxBatch`, i.e. **[M-4]**, still genuinely open but narrow: it needs an owner that is a
contract blindly proxying token callbacks, so EOA owners are unaffected. Left alone by decision.

For `OpenVolatileLPManager` the residual was never re-entry — it is the delta problem (H-6), which risks
1–3 of its header describe and `test_brickingHook_trapsPrincipal` demonstrates.

## Edits

- **`audits/2026-05-17/AUDIT-REPORT.md`** — four places, because the false premise had propagated upward:
  the [M-3] entry gets a dated `RESOLUTION … NOT APPLICABLE` block (original description and
  recommendation kept **verbatim** — an audit record should be annotated, not rewritten); the executive
  summary's "can drive nested unlocks" clause (`:24`) is withdrawn; the recommended-mitigations list
  (`:27`) drops `nonReentrant` on `unlockCallback`; and the "Hook trust gap" cluster (`:361-364`) drops
  M-3 from its membership and strikes remediation item 2. The resolution block also records that the
  finding's locations (`openPosition`/`closePosition`/`decreasePosition`/`pokePosition`) belonged to
  `UniSmartWallet`, removed in task_025.
- **`audits/2026-07-18/AUDIT-REPORT.md:84-88`** — my task_043 note corrected. Worth noting it had
  contradicted its own document: the Reentrancy bullet further down already said "v4 реверт вложенного
  `unlock`".
- **`src/OpenVolatileLPManager.sol`** — risk #4 removed from the accepted-risks list and replaced with an
  explicit "what is NOT on this list, despite hooks now running inside our `unlock`" paragraph. The old
  text **overstated** the product's danger; a risk list that is inflated is as unhelpful as one that is
  short, and this one has to be trusted by whoever chooses the implementation.
- **`tasks/task_043_open_volatile_manager.md`** — risk 4 and the "[M-3] hardening" follow-up struck
  through with the reason; the historical sentence about why the gate was narrowed in task_012 is kept
  (it correctly reports what the audit *contained*) but qualified.
- **`CLAUDE.md`** — nothing needed; verified its § Hook policy only ever cited [H-6] and [H-7]/[M-7].

## Verification

`forge build --sizes` byte-identical, `forge fmt --check` clean, `forge test` 222 passed / 3 skipped —
nothing executable was touched. Both inventory sweeps re-run; every remaining hit for `M-3]` or for
"nonReentrant … unlockCallback" is either original audit text or a withdrawal note, with no live claim
that the finding is open:

```bash
grep -rn "M-3\]" --include='*.md' --include='*.sol' . | grep -vE "^\./(lib|out|cache)/"
grep -rniE "nonReentrant.{0,30}unlockCallback|unlockCallback.{0,30}nonReentrant" \
  --include='*.md' --include='*.sol' . | grep -vE "^\./(lib|out|cache)/"
```

## Note for whoever resolves the next finding

This report had **no status convention at all** — no findings table, no RESOLVED/ACCEPTED markers on any
entry. Mine is the first inline resolution, and I deliberately did not add a suffix to the `#### [M-3] …`
heading, since inventing a convention for one finding is worse than none. If more findings get resolved,
add a status column properly rather than by accretion.
