// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Minimal unlock caller: moves liquidity between two pools inside ONE `unlock`, and counts
/// how many times it actually paid or was paid. Deliberately not one of the managers — the question
/// is what v4 permits, so nothing of ours is in the way.
contract CrossPoolMover is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;

    uint256 public settleCalls;
    uint256 public takeCalls;
    /// @dev Nonzero currency deltas outstanding at the moment the last op finished, before settlement.
    uint256 public deltasBeforeSettle;

    struct Move {
        PoolKey from;
        PoolKey to;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity; // pulled out of `from` and put into `to`
        bool swapFirst; // route the freed side through a third leg before re-adding
        PoolKey via;
        bool zeroForOne;
        int256 amountSpecified;
    }

    constructor(IPoolManager pm) {
        POOL_MANAGER = pm;
    }

    function move(Move calldata m) external {
        POOL_MANAGER.unlock(abi.encode(uint8(1), abi.encode(m)));
    }

    /// @dev Open the starting position under THIS contract's address (v4 keys a position by whoever
    /// calls `modifyLiquidity`), paid out of this contract's own balance.
    function open(PoolKey calldata key, int24 tl, int24 tu, uint128 liq) external {
        POOL_MANAGER.unlock(abi.encode(uint8(0), abi.encode(key, tl, tu, liq)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "not pm");
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == 0) {
            (PoolKey memory k, int24 tl, int24 tu, uint128 liq) = abi.decode(payload, (PoolKey, int24, int24, uint128));
            POOL_MANAGER.modifyLiquidity(
                k,
                ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(liq)), salt: 0}),
                ""
            );
            _resolve(k.currency0);
            _resolve(k.currency1);
            return "";
        }
        Move memory m = abi.decode(payload, (Move));

        // 1. Pull the whole position out of pool `from` — credits us both of its currencies.
        POOL_MANAGER.modifyLiquidity(
            m.from,
            ModifyLiquidityParams({
                tickLower: m.tickLower, tickUpper: m.tickUpper, liquidityDelta: -int256(uint256(m.liquidity)), salt: 0
            }),
            ""
        );

        // 2. Optionally convert one freed leg in a third pool (still the same unlock).
        if (m.swapFirst) {
            POOL_MANAGER.swap(
                m.via,
                SwapParams({
                    zeroForOne: m.zeroForOne,
                    amountSpecified: m.amountSpecified,
                    sqrtPriceLimitX96: m.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        }

        // 3. Put the liquidity into pool `to` — debits us, netting against the credit from step 1.
        POOL_MANAGER.modifyLiquidity(
            m.to,
            ModifyLiquidityParams({
                tickLower: m.tickLower, tickUpper: m.tickUpper, liquidityDelta: int256(uint256(m.liquidity)), salt: 0
            }),
            ""
        );

        deltasBeforeSettle = POOL_MANAGER.getNonzeroDeltaCount();

        // 4. One settlement pass over the currency union — NOT one per pool, and not one per op.
        Currency[] memory union = _union(m);
        for (uint256 i = 0; i < union.length; ++i) {
            int256 d = POOL_MANAGER.currencyDelta(address(this), union[i]);
            if (d < 0) {
                ++settleCalls;
                POOL_MANAGER.sync(union[i]);
                union[i].transfer(address(POOL_MANAGER), uint256(-d));
                POOL_MANAGER.settle();
            } else if (d > 0) {
                ++takeCalls;
                POOL_MANAGER.take(union[i], address(this), uint256(d));
            }
        }
        return "";
    }

    function _resolve(Currency c) private {
        int256 d = POOL_MANAGER.currencyDelta(address(this), c);
        if (d < 0) {
            POOL_MANAGER.sync(c);
            c.transfer(address(POOL_MANAGER), uint256(-d));
            POOL_MANAGER.settle();
        } else if (d > 0) {
            POOL_MANAGER.take(c, address(this), uint256(d));
        }
    }

    /// @dev Deduped currencies of every pool this move touched.
    function _union(Move memory m) private pure returns (Currency[] memory out) {
        Currency[] memory all = new Currency[](6);
        all[0] = m.from.currency0;
        all[1] = m.from.currency1;
        all[2] = m.to.currency0;
        all[3] = m.to.currency1;
        all[4] = m.swapFirst ? m.via.currency0 : m.from.currency0;
        all[5] = m.swapFirst ? m.via.currency1 : m.from.currency1;

        Currency[] memory tmp = new Currency[](6);
        uint256 n;
        for (uint256 i = 0; i < 6; ++i) {
            bool seen;
            for (uint256 j = 0; j < n; ++j) {
                if (Currency.unwrap(tmp[j]) == Currency.unwrap(all[i])) seen = true;
            }
            if (!seen) tmp[n++] = all[i];
        }
        out = new Currency[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = tmp[i];
        }
    }
}

/// @notice Does v4 allow several pools inside one `unlock`, ending in a single settlement pass?
/// Answered by doing it: liquidity is pulled out of one pool and put into another (a different fee
/// tier, then a different pair via an intermediate swap) within one unlock, and the settlement is
/// counted.
contract CrossPoolUnlockTest is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal pm;
    PoolModifyLiquidityTest internal lpRouter;
    CrossPoolMover internal mover;

    Currency internal USDT;
    Currency internal USDC;
    Currency internal DAI;

    PoolKey internal poolA; // USDT/USDC, fee 3000 — the position starts here
    PoolKey internal poolB; // USDT/USDC, fee 500  — and is moved here
    PoolKey internal poolC; // USDT/DAI,  fee 3000 — the different-pair destination
    PoolKey internal poolD; // USDC/DAI,  fee 3000 — the intermediate swap leg

    address internal lp = address(0xABCD);
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;
    uint128 internal constant L = 1_000e18;

    function setUp() public {
        pm = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        mover = new CrossPoolMover(IPoolManager(address(pm)));

        USDT = _mkToken();
        USDC = _mkToken();
        DAI = _mkToken();

        poolA = _key(USDT, USDC, 3000);
        poolB = _key(USDT, USDC, 500);
        poolC = _key(USDT, DAI, 3000);
        poolD = _key(USDC, DAI, 3000);
        PoolKey[4] memory keys = [poolA, poolB, poolC, poolD];
        for (uint256 i = 0; i < 4; ++i) {
            pm.initialize(keys[i], TickMath.getSqrtPriceAtTick(0));
            _seed(keys[i]);
        }

        // The mover's own float: the dust the netting cannot cover comes from here.
        MockERC20(Currency.unwrap(USDT)).mint(address(mover), 10_000e18);
        MockERC20(Currency.unwrap(USDC)).mint(address(mover), 10_000e18);
        MockERC20(Currency.unwrap(DAI)).mint(address(mover), 10_000e18);
    }

    /// The classic rebalance: same pair, two fee tiers, one unlock. Both pools are touched, and the
    /// whole thing settles in ONE pass over the two currencies — not one settlement per pool.
    function test_moveLiquidityBetweenTwoPools_oneUnlock_oneSettlementPass() public {
        _openMoverPosition(poolA);

        uint256 usdtBefore = _bal(USDT, address(mover));
        uint256 usdcBefore = _bal(USDC, address(mover));

        mover.move(
            CrossPoolMover.Move({
                from: poolA,
                to: poolB,
                tickLower: TL,
                tickUpper: TU,
                liquidity: L,
                swapFirst: false,
                via: poolA,
                zeroForOne: false,
                amountSpecified: 0
            })
        );

        assertEq(_liquidity(poolA), 0, "pool A position closed");
        assertEq(_liquidity(poolB), L, "pool B position opened");
        // Two currencies, so at most two settlement calls in total — and because the two pools sit at
        // the same price, the amounts net to a rounding remainder rather than a full round trip.
        assertLe(mover.settleCalls() + mover.takeCalls(), 2, "one pass over the currency union");
        console2.log("A->B  deltas before settlement:", mover.deltasBeforeSettle());
        console2.log("A->B  settle calls:", mover.settleCalls());
        console2.log("A->B  take calls:", mover.takeCalls());
        console2.log("A->B  USDT moved through the mover's balance:", _diff(usdtBefore, _bal(USDT, address(mover))));
        console2.log("A->B  USDC moved through the mover's balance:", _diff(usdcBefore, _bal(USDC, address(mover))));
    }

    /// The harder case: a different PAIR. Pull out of USDT/USDC, swap the freed USDC into DAI in a
    /// third pool, add into USDT/DAI — three pools, one unlock, one settlement pass over the union.
    function test_moveLiquidityAcrossPairs_withIntermediateSwap_oneUnlock() public {
        _openMoverPosition(poolA);

        mover.move(
            CrossPoolMover.Move({
                from: poolA,
                to: poolC,
                tickLower: TL,
                tickUpper: TU,
                liquidity: L,
                swapFirst: true,
                via: poolD,
                // USDC -> DAI in pool D, exact-in of what the pull freed on that side.
                zeroForOne: Currency.unwrap(poolD.currency0) == Currency.unwrap(USDC),
                amountSpecified: -int256(2e18)
            })
        );

        assertEq(_liquidity(poolA), 0, "source pool emptied");
        assertEq(_liquidity(poolC), L, "destination pool funded");
        assertLe(mover.settleCalls() + mover.takeCalls(), 4, "one pass over the 3-currency union");
        console2.log("A->C  deltas before settlement:", mover.deltasBeforeSettle());
        console2.log("A->C  settle calls:", mover.settleCalls());
        console2.log("A->C  take calls:", mover.takeCalls());
    }

    /// The counter-check: leaving any currency unsettled fails the whole unlock, whatever the pools
    /// did — the `NonzeroDeltaCount != 0` gate at the end of `PoolManager.unlock`.
    function test_unsettledCurrency_revertsTheWholeUnlock() public {
        _openMoverPosition(poolA);
        BadMover bad = new BadMover(IPoolManager(address(pm)));
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        bad.touchTwoPoolsAndWalkAway(poolA, poolB);
    }

    // ────────── helpers ──────────

    function _openMoverPosition(PoolKey memory key) internal {
        mover.open(key, TL, TU, L);
    }

    function _liquidity(PoolKey memory key) internal view returns (uint128) {
        return IPoolManager(address(pm)).getPositionLiquidity(key.toId(), _posKey(address(mover)));
    }

    function _posKey(address owner_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner_, TL, TU, bytes32(0)));
    }

    function _mkToken() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20()));
    }

    function _key(Currency a, Currency b, uint24 fee) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: 60, hooks: IHooks(address(0))});
    }

    function _seed(PoolKey memory key) internal {
        uint256 amt = 2_000_000e18;
        MockERC20(Currency.unwrap(key.currency0)).mint(lp, amt);
        MockERC20(Currency.unwrap(key.currency1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}

/// @dev Touches two pools and settles nothing — the unlock must revert.
contract BadMover is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager pm) {
        POOL_MANAGER = pm;
    }

    function touchTwoPoolsAndWalkAway(PoolKey calldata a, PoolKey calldata b) external {
        POOL_MANAGER.unlock(abi.encode(a, b));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory a, PoolKey memory b) = abi.decode(data, (PoolKey, PoolKey));
        // Both swaps are allowed while unlocked; what is not allowed is leaving the unlock with the
        // resulting currency deltas open.
        POOL_MANAGER.swap(
            a,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        POOL_MANAGER.swap(
            b,
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        return "";
    }
}
