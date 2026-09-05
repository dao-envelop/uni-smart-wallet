// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";

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

/// @notice Audit 2026-09-04, H-1 — kept as a regression after task_053 closed it.
///
/// The attack: a compromised operator extracts principal WITHOUT any manager swap. It skews a configured
/// pool's spot price with its own capital, re-deploys the manager's principal at that price through a
/// swapless `moveLiquidity` / `recenter`, then trades the price back through the manager's freshly
/// concentrated liquidity — the manager buys the pumped token at the pumped price and the attacker
/// pockets the difference (measured here at -22.4% and -44.5% of the portfolio before the fix). Same
/// mechanism as the Gamma Strategies (2024-01) and Beefy CLM (Cyfrin) findings.
///
/// What made it work was that a swapless op never reached the oracle: `_guardSwap` sat on the swap paths
/// only, and the add sized L from `getSlot0` with no reference. These tests now assert the two ways that
/// is shut: no oracle ⇒ an operator cannot add at all, and with one wired the skewed pool is refused. The
/// unskewed control keeps the gate honest — it must not simply block every operator op.
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
        // No price oracle is wired here: that is the pre-task_053 world the attack was found in, and the
        // first two tests below pin what it costs an operator now. `_wireOracle` opts into the fixed one.

        MockERC20(Currency.unwrap(c0)).mint(bot, 10_000e18);
        MockERC20(Currency.unwrap(c1)).mint(bot, 10_000e18);
        vm.startPrank(bot);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ────────── the attack, through moveLiquidity (task_051) ──────────

    function test_H1_swaplessMoveIntoSkewedPool_isRejected() public {
        uint128 liq = _open(poolA, SALT_A, -60, 60, 500e18);
        uint256 mgrBefore = _managerValue();

        // 1. Pump the thin configured pool with the attacker's own capital (no manager involvement).
        _swap(keyB, false, PUMP_TICK);
        (, int24 tick,,) = IPoolManager(address(poolManager)).getSlot0(poolB);
        assertGe(tick, PUMP_TICK - 1, "pool B skewed");

        // 2. The move that used to deploy the whole principal at the skewed price. With no oracle the
        //    operator cannot add at all; the owner still can (they accept their own slippage).
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, PUMP_TICK - 60, PUMP_TICK + 60, 499e18));

        // 3. With the oracle wired it is the skew itself that is refused, not the missing reference.
        _wireOracle();
        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, PUMP_TICK - 60, PUMP_TICK + 60, 499e18));

        assertEq(mgr.positionOf(SALT_B).liquidity, 0, "no principal was deployed at the skewed price");
        assertEq(_managerValue(), mgrBefore, "portfolio untouched");
    }

    // ────────── the same, in-pool, through recenter (pre-existing surface) ──────────

    function test_H1_swaplessRecenterAtSkewedPrice_isRejected() public {
        _open(poolB, SALT_B, -60, 60, 500e18);

        _swap(keyB, false, PUMP_TICK);
        // Measured after the pump: it traded through the manager's own position, which is ordinary LP
        // toxic flow and not what this test is about. What must not happen is the *re-deployment* at the
        // skewed price that turned that flow into an extraction.
        uint256 mgrAfterPump = _managerValue();
        _wireOracle();

        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.recenter(_skewedRecenter());

        assertEq(mgr.positionOf(SALT_B).tickLower, int24(-60), "position stayed at its original range");
        assertEq(_managerValue(), mgrAfterPump, "nothing was re-deployed at the skewed price");
    }

    /// @dev The control: the same operator, the same call, on an unskewed pool. The gate bounds the price
    /// an operator may deploy at — it does not take recentering away from the bot.
    function test_H1_operatorRecenter_unskewedPool_stillWorks() public {
        _open(poolB, SALT_B, -60, 60, 500e18);
        _wireOracle();

        vm.prank(bot);
        mgr.recenter(
            VolatileLPManager.RecenterParams({
                salt: SALT_B,
                newTickLower: -120,
                newTickUpper: 120,
                zeroForOne: false,
                swapAmountIn: 0,
                swapPriceLimit: 0,
                minAmountOut: 0,
                minLiquidity: 0
            })
        );
        assertEq(mgr.positionOf(SALT_B).tickLower, int24(-120), "operator recenter at a sane price");
    }

    /// @dev Wire the real oracle: both currencies at $1, so a 1:1 pool sits exactly on the reference and
    /// the +6000-tick pump (~+82%) is far outside the 50 bps spot tolerance.
    function _wireOracle() internal {
        ChainlinkPriceOracle oracle =
            new ChainlinkPriceOracle(address(this), IPoolManager(address(poolManager)), 100, 50, address(0), 0);
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        oracle.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
    }

    /// @dev The recenter the attack used: the freed position is single-sided (all token1 after the pump),
    /// so the new range sits entirely below the skewed price — it holds only token1 and buys token0 on
    /// the way down.
    function _skewedRecenter() internal pure returns (VolatileLPManager.RecenterParams memory) {
        return VolatileLPManager.RecenterParams({
            salt: SALT_B,
            newTickLower: PUMP_TICK - 120,
            newTickUpper: PUMP_TICK - 60,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            minLiquidity: 0
        });
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
