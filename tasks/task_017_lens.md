# Task 017 — UniLens (frontend read aggregator)

## Goal
A stateless view contract so a frontend reads a whole open-position portfolio in one call, instead of N
RPC round-trips or parsing the base64/SVG `tokenURI` (which targets marketplaces, not apps).

## What was built
`src/UniLens.sol` — holds no state, serves **both** products (`UniSmartWallet` and `StableLPManager`)
because both inherit `V4PositionManager` and expose the same getters. Reuses `src/lib/PositionState.sol`
(`value` is view-only, no `unlock`) — the same valuation the on-chain descriptor uses.

- `position(wallet, salt)` / `positions(wallet)` → `PositionView{salt, key, ticks, liquidity, openedAt,
  sqrtPriceX96, amount0, amount1, fees0, fees1}` per open position (principal split at the live price +
  uncollected fees + pool price).
- `managerInfo(manager)` → `ManagerView{owner, protocolFeeBps, treasury, managedStables[],
  idleBalances[], pools[]}` for the `StableLPManager` manage/deposit UI.
- No oracle: raw token amounts (USD is the frontend's job; stables ≈ par). Separate contract ⇒ no
  EIP-170 impact on the wallets, existing contracts untouched.

## Tests (`test/UniLens.t.sol`)
- Wallet: 2 positions + real swaps → each `PositionView` equals `positionOf` + `PositionState.value`
  (liquidity/ticks/amounts/fees) and `sqrtPriceX96` equals `getSlot0`; fees carried through after swaps;
  `positions().length == openPositionCount()`.
- Manager: portfolio after a 3-leg `allocate`; `managerInfo` returns owner/treasury/fee/managed set
  (4 stables) + idle balances (USDT idle == FUND) + 3 configured pools.

## Notes
- `StableLPManager.PoolConfig[] public pools` auto-getter returns a flattened tuple
  `(PoolKey, int24, int24)`, so `managerInfo` destructures and rebuilds each `PoolConfig`.
- Lens is unaware of the concrete product; one deployment per chain serves every wallet/manager.
