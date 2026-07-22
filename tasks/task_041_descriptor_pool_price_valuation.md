# task_041 — descriptor values volatile positions at the pool price (stable leg = $1)

Change `src/WalletPositionDescriptor.sol` so a position's "Total value" is computed from the **live pool
price** (`sqrtPriceX96`) with a stablecoin leg anchored at $1, instead of the current naive "1 token = $1"
model — which undervalues volatile legs (ETH/WBTC) on volatile managers.

> **Scope = contract + tests + deploy wiring.** Frontend needs only a deployments re-sync after deploy
> (the stale-descriptor UI already handles migration — see below). Full plan:
> `~/.claude/plans/wiggly-honking-patterson.md`.

## Why

The NFT card renders "Total value" via `_positionUsd` using `amount / 10^decimals × $1` for BOTH legs
(`WalletPositionDescriptor.sol:101-112`, `USD = 1e18`). That's fine for stable pairs but treats ETH/WBTC
as $1 each on volatile managers. Live example — arbitrum manager `0x60723973ABF3BBC2ce7EB4400B728390D55e264b`
(3 positions in ETH/USDC + WBTC/USDC): NFT shows **$12.02**, real value of those positions is **~$16.80**;
the ~$4.78 gap is the ETH/WBTC legs priced at $1. Fix: value the volatile leg through the pool price,
denominated in the stable leg (treated as $1).

**One descriptor for many managers — confirmed YES (no change needed to that).** The descriptor is
**stateless**: a manager delegates `tokenURI(id)` → `IWalletDescriptor(descriptor).tokenURI(address(this), id)`
(`BaseLPManager.sol:332-337`), passing itself. One deployed instance per chain serves every EIP-1167 clone.
The stablecoin allowlist added here is **per-chain** (constructor arg), so it stays one-descriptor-per-chain
for all managers — not per-manager.

## Contract — `src/WalletPositionDescriptor.sol`

Current: no constructor, no state (only constants). Deployed size ≈ 18,224 B; EIP-170 headroom ≈ 6.3 KB —
ample for the price math + a small set.

1. **Stablecoin set + constructor.** Add `mapping(address => bool) private isStable;` and
   `constructor(address[] memory stablecoins)` that sets each to true. (First state var — fine; it's a
   standalone, non-clone contract.)

2. **Rework `_positionUsd`** (`:101-112`) — pool-price valuation with a stable anchor; keep the naive
   $1/token model as the fallback for pairs with NO stable leg (no on-chain USD anchor otherwise):
   ```solidity
   (uint256 a0,a1,f0,f1) = PositionState.value(pm, w, salt, p);
   uint256 unit0 = 10**_decimals(p.key.currency0); uint256 unit1 = 10**_decimals(p.key.currency1);
   address c0 = Currency.unwrap(p.key.currency0); address c1 = Currency.unwrap(p.key.currency1);
   if (isStable[c1]) {                       // token1 = $1; convert token0 → token1 at pool price
       (uint160 sp,,,) = pm.getSlot0(p.key.toId());
       principalUsd = a1*USD/unit1 + _q0to1(a0, sp)*USD/unit1;
       feeUsd       = f1*USD/unit1 + _q0to1(f0, sp)*USD/unit1;
   } else if (isStable[c0]) {                // token0 = $1; convert token1 → token0
       (uint160 sp,,,) = pm.getSlot0(p.key.toId());
       principalUsd = a0*USD/unit0 + _q1to0(a1, sp)*USD/unit0;
       feeUsd       = f0*USD/unit0 + _q1to0(f1, sp)*USD/unit0;
   } else {                                  // no stable anchor → keep naive $1/token
       principalUsd = a0*USD/unit0 + a1*USD/unit1;
       feeUsd       = f0*USD/unit0 + f1*USD/unit1;
   }
   ```
   Conversion helpers (raw→raw, two-step `FullMath.mulDiv` = 512-bit, overflow-safe), libs already
   available (imported in `PositionState`): `FullMath`, `FixedPoint96.Q96`, `StateLibrary` (`getSlot0`),
   `PoolId`/`toId`:
   ```solidity
   // token0 raw → token1 raw:  a0 * (sqrtP/2^96)^2
   function _q0to1(uint256 a0, uint160 sp) private pure returns (uint256) {
       return FullMath.mulDiv(FullMath.mulDiv(a0, sp, Q96), sp, Q96);
   }
   // token1 raw → token0 raw:  a1 / (sqrtP/2^96)^2
   function _q1to0(uint256 a1, uint160 sp) private pure returns (uint256) {
       return FullMath.mulDiv(FullMath.mulDiv(a1, Q96, sp), Q96, sp);
   }
   ```
   Mirrors `OracleLibrary.getQuoteAtTick` (ratioX128 branch) but native to v4 `sqrtPriceX96`. Native ETH
   (`address(0)`) → `isStable` false → treated as the volatile leg (correct for ETH/USDC). `_positionJson`/
   `_amounts` (raw amounts) unchanged — only USD aggregation changes; APR denominator (`principalUsd`)
   becomes correct as a side effect. Add the imports (`StateLibrary`, `FullMath`, `FixedPoint96`, `PoolId`).

3. Run `forge build --sizes` — keep it < 24,576 B.

## Deploy — `script/DeployStableLP.s.sol` + `script/chain_params.json`

- Add a per-chain `"stablecoins": ["0x…", …]` field to `chain_params.json` (values = the same lists as the
  frontend `stablelp-ui/config/stablecoins.ts`). Read it with a new `_optAddrArray` helper (copy the
  `_readOracle` pattern, `:279-288`), thread through `Config` (struct ~229-236) → `deployComponents` →
  replace `new WalletPositionDescriptor()` (`:183`) with `new WalletPositionDescriptor(stables)`. The
  `descriptor` output plumbing (`:351/367`) is unchanged. Set `deploy.descriptor: true` for the chains you
  render on. Redeploy on 1/130/8453/42161 (1301 optional).

## Migration (frontend — already handled)

After deploy, `node scripts/sync-deployments.mjs` in `stablelp-ui` pulls the new `descriptor` address.
Existing managers point at the OLD descriptor → the app already shows `DescriptorNotice` ("Descriptor update
available") and the owner re-points via `setPositionDescriptor` (hook `useSetDescriptor`). No forced
migration, no funds moved. New managers get the current descriptor at init.

## Verification

- `forge fmt`, `forge test -vvv`, `forge build --sizes`.
- **New test** in `test/WalletPositionDescriptor.t.sol`: the `V4WalletTestBase` pool is initialized at
  **tick 0 (1:1)**, so add a pool at a **non-zero tick** (different `sqrtPriceX96`) with one leg marked in
  `isStable`, open a position, and assert the rendered `Total Value (USD)` matches the price-weighted
  expectation (not the naive sum). Add a no-stable-pair case asserting the naive fallback still applies.
  Assertion style = ffi base64-decode of the JSON (`test_tokenURI_totalValueAndApr_render`).
- **After deploy — live:** decode `tokenURI(1)` SVG on arb `0x60723973ABF3BBC2ce7EB4400B728390D55e264b`;
  its per-position "Total value" should rise from ~$12 toward the real ~$16–17 (cross-check with UniLens
  `managerFull` amount0/1 × market price). Idle is still excluded from the NFT number by design (positions
  only).

## Notes

- The NFT stays a **pool-spot** estimate (not a market oracle) — close to real for stable-paired pools; for
  pairs with no stable leg it keeps the naive $1/token fallback (honest limitation without an oracle).
- Do not change `IWalletDescriptor.tokenURI` signature or the `EnvelopV2OracleType`/`EnvelopWrappedV2` events.
