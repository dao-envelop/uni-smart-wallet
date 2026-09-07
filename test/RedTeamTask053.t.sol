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

/// @notice RED TEAM harness for task_053 (`_guardSwap(byOwner, key, true, 0, 0)` on operator add paths).
///
/// The fix bounds the price an operator may deploy principal at to `maxSpotDeviationBps` (50 bps) of the
/// Chainlink reference. It does NOT bound how often the operator may do it. Everything below stays
/// INSIDE the gate — every call succeeds — and measures what leaks.
abstract contract RedTeamBase is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal pm;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    VolatileLPManager internal mgr;
    ChainlinkPriceOracle internal oracle;

    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal pid;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07); // compromised operator == the attacker's trading account
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);
    address internal griefer = address(0x6111E5); // unprivileged third party

    bytes32 internal constant SALT = bytes32(uint256(1));

    int24 internal spacing;

    // ────────── harness ──────────

    /// @param fee            pool fee (pips)
    /// @param spacing_       tick spacing
    /// @param poolLiquidity  full-range liquidity from an unrelated LP (the pool's depth)
    /// @param fund0          the manager's principal in currency0
    /// @param fund1          the manager's principal in currency1
    function _boot(uint24 fee, int24 spacing_, uint256 poolLiquidity, uint256 fund0, uint256 fund1) internal {
        spacing = spacing_;
        pm = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing_, hooks: IHooks(address(0))});
        pid = key.toId();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        MockERC20(Currency.unwrap(c0)).mint(lp, 1e32);
        MockERC20(Currency.unwrap(c1)).mint(lp, 1e32);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -(887272 / spacing_) * spacing_,
                tickUpper: (887272 / spacing_) * spacing_,
                liquidityDelta: int256(poolLiquidity),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(pm)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = key;
        mgr.initialize(
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
        );
        if (fund0 > 0) MockERC20(Currency.unwrap(c0)).mint(address(mgr), fund0);
        if (fund1 > 0) MockERC20(Currency.unwrap(c1)).mint(address(mgr), fund1);

        vm.prank(owner);
        mgr.setOperator(bot, true);

        // The REAL oracle: both currencies at $1, swap tolerance 100 bps, spot tolerance 50 bps.
        oracle = new ChainlinkPriceOracle(address(this), IPoolManager(address(pm)), 100, 50, 10, address(0), 0);
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        oracle.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));

        _fundTrader(bot);
        _fundTrader(griefer);
    }

    function _fundTrader(address who) internal {
        MockERC20(Currency.unwrap(c0)).mint(who, 1e32);
        MockERC20(Currency.unwrap(c1)).mint(who, 1e32);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ────────── helpers ──────────

    function _tick() internal view returns (int24 t) {
        (, t,,) = IPoolManager(address(pm)).getSlot0(pid);
    }

    function _sqrt() internal view returns (uint160 s) {
        (s,,,) = IPoolManager(address(pm)).getSlot0(pid);
    }

    function _rawSlot0() internal view returns (uint160, int24, uint24, uint24) {
        return IPoolManager(address(pm)).getSlot0(pid);
    }

    /// @dev An unbounded exact-in swap (no meaningful price limit) executed by `who`.
    function _swapExactInAs(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Trade in `key` until the price reaches `limitTick` (exact-in, oversized: the limit stops it).
    function _swapTo(int24 limitTick) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(limitTick);
        uint160 cur = _sqrt();
        if (cur == target) return; // already there: v4 would revert `PriceLimitAlreadyExceeded`
        _swapToAs(bot, limitTick);
    }

    function _swapToAs(address who, int24 limitTick) internal {
        uint160 target = TickMath.getSqrtPriceAtTick(limitTick);
        uint160 cur = _sqrt();
        if (cur == target) return;
        bool zeroForOne = target < cur;
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e29),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _openAsOwner(int24 tl, int24 tu, uint256 amt) internal {
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(SALT, tl, tu, amt, amt);
        vm.prank(owner);
        mgr.allocate(legs);
    }

    function _leg(bytes32 salt, int24 tl, int24 tu, uint256 a0, uint256 a1)
        internal
        view
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
            amount0Desired: a0,
            amount1Desired: a1,
            minLiquidity: 0
        });
    }

    function _recenterAsBot(int24 tl, int24 tu) internal {
        vm.prank(bot);
        mgr.recenter(
            VolatileLPManager.RecenterParams({
                salt: SALT,
                newTickLower: tl,
                newTickUpper: tu,
                zeroForOne: false,
                swapAmountIn: 0,
                swapPriceLimit: 0,
                minAmountOut: 0,
                minLiquidity: 0
            })
        );
    }

    /// @dev A recenter whose own pre-swap moves the pool before the add's spot check reads it.
    function _recenterWithSwap(address who, int24 tl, int24 tu, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who);
        mgr.recenter(
            VolatileLPManager.RecenterParams({
                salt: SALT,
                newTickLower: tl,
                newTickUpper: tu,
                zeroForOne: zeroForOne,
                swapAmountIn: amountIn,
                swapPriceLimit: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                minAmountOut: 0,
                minLiquidity: 0
            })
        );
    }

    function _allocateAs(address who, VolatileLPManager.VolatileAllocLeg[] memory legs) internal {
        vm.prank(who);
        mgr.allocate(legs);
    }

    function _valueOf(address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c0)).balanceOf(who) + MockERC20(Currency.unwrap(c1)).balanceOf(who);
    }

    /// @dev Everything the manager owns, valued at the TRUE reference price (1:1): idle + principal + fees.
    function _managerValue() internal view returns (uint256 v) {
        v = MockERC20(Currency.unwrap(c0)).balanceOf(address(mgr))
            + MockERC20(Currency.unwrap(c1)).balanceOf(address(mgr));
        V4PositionManager.Position memory p = mgr.positionOf(SALT);
        if (p.liquidity == 0) return v;
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
            PositionState.value(IPoolManager(address(pm)), address(mgr), SALT, p);
        v += a0 + a1 + f0 + f1;
    }

    function _botValue() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c0)).balanceOf(bot) + MockERC20(Currency.unwrap(c1)).balanceOf(bot);
    }
}
