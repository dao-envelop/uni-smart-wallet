// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice TARGET 5 — everything else that was tried against the gate.
contract RedTeamT5Misc is RedTeamBase {
    /// @dev NEGATIVE RESULT. Every path that reaches `modifyLiquidity` with a POSITIVE delta funnels
    /// through `VolatileLPManager._addLiquidityAt` (src/VolatileLPManager.sol:270) or
    /// `StableLPManager._addLiquidity` (src/StableLPManager.sol:203), both of which now call
    /// `_guardSwap` before the add. Clearing the oracle makes every one of them revert for an
    /// operator; the remaining `modifyLiquidity` call sites in `src` all pass `liquidityDelta <= 0`
    /// (`_handleClaim` x2, `_handleReinvest`'s fee poke, `BaseLPManager._pullLiquidity`).
    function test_T5a_noUnguardedAddPathForAnOperator() public {
        _boot(100, 1, 100_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-100, 100, 500e18);

        vm.prank(owner);
        mgr.setPriceOracle(address(0)); // the gate's fail-closed extreme

        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(bytes32(uint256(7)), -100, 100, 100e18, 100e18);

        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.allocate(legs);

        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.recenter(
            VolatileLPManager.RecenterParams({
                salt: SALT,
                newTickLower: -200,
                newTickUpper: 200,
                zeroForOne: false,
                swapAmountIn: 0,
                swapPriceLimit: 0,
                minAmountOut: 0,
                minLiquidity: 0
            })
        );

        uint128 open = mgr.positionOf(SALT).liquidity;
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.moveLiquidity(SALT, open, legs[0]);

        // A pure fee claim still works: it adds nothing, so it is not gated.
        vm.prank(bot);
        mgr.claimFees(SALT);
    }

    /// @dev NEGATIVE RESULT for the operator role itself, POSITIVE for a nearby footgun. `byOwner`
    /// comes from `BaseLPManager._isOwnerCall` (src/BaseLPManager.sol:340), a strict
    /// `ownerOf(TOKEN_ID) == msg.sender`, so `setOperator` can never produce it. But the manager IS an
    /// ERC-721: an ordinary token approval to the same hot address hands over ownership, and with it
    /// the whole bypass plus `withdrawTo`.
    function test_T5b_operatorCannotBecomeOwner_unlessApprovedTheNft() public {
        _boot(100, 1, 100_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-100, 100, 500e18);
        _swapToAs(griefer, 60); // out of band

        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.recenter(_r(-60, 60));

        // Operator approval alone does nothing for `byOwner`.
        vm.prank(owner);
        mgr.setOperator(bot, true);
        vm.prank(bot);
        vm.expectPartialRevert(ChainlinkPriceOracle.SpotPriceOutOfBounds.selector);
        mgr.recenter(_r(-60, 60));

        // An ERC-721 approval, however, is a different thing entirely.
        vm.prank(owner);
        mgr.setApprovalForAll(bot, true);
        vm.prank(bot);
        mgr.transferFrom(owner, bot, 1);
        vm.prank(bot);
        mgr.recenter(_r(-60, 60)); // now `byOwner == true`: the gate is gone
        assertEq(mgr.positionOf(SALT).tickLower, int24(-60), "NFT approval == full bypass");
    }

    /// @dev NEGATIVE RESULT. `_checkSpot` reads the ORACLE's own immutable `POOL_MANAGER`
    /// (src/oracle/ChainlinkPriceOracle.sol:283). Point a manager at an oracle built for a different
    /// PoolManager and the pool reads as uninitialized ⇒ `check` returns false ⇒ operators fail closed.
    /// There is no configuration in which a skewed pool reads as vouched-for.
    function test_T5c_oracleBoundToItsOwnPoolManager() public {
        _boot(100, 1, 100_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-100, 100, 500e18);

        PoolManager other = new PoolManager(address(this));
        ChainlinkPriceOracle wrong =
            new ChainlinkPriceOracle(address(this), IPoolManager(address(other)), 100, 50, address(0), 0);
        wrong.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        wrong.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        vm.prank(owner);
        mgr.setPriceOracle(address(wrong));

        vm.prank(bot);
        vm.expectPartialRevert(BaseLPManager.OperatorSwapUnverified.selector);
        mgr.recenter(_r(-60, 60));
    }

    function _r(int24 tl, int24 tu) internal pure returns (VolatileLPManager.RecenterParams memory) {
        return VolatileLPManager.RecenterParams({
            salt: SALT,
            newTickLower: tl,
            newTickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            minLiquidity: 0
        });
    }
}

/// @notice TARGET 5, second half — the `amountIn == 0` sentinel.
///
/// `ChainlinkPriceOracle.check` reads `amountIn == 0` as "judge the pool's spot price instead of the
/// swap" (src/oracle/ChainlinkPriceOracle.sol:230-247). Its safety argument, written into that
/// comment, is that no real swap can wear the sentinel because every swap path "has already required
/// [the realized input] to be no smaller than the requested one". That is true of
/// `VolatileLPManager._guardedSwap` (src/VolatileLPManager.sol:222) and of
/// `StableLPManager._allocateLeg` (src/StableLPManager.sol:189). It is NOT true of
/// `StableLPManager._handleReinvest` (src/StableLPManager.sol:292-299), which calls `_guardSwap` with
/// the realized deltas and has no full-fill check at all.
///
/// This test establishes the enabling mechanism: a v4 exact-in swap CAN realize a zero input while
/// still moving the pool price, because `Pool.swap`'s loop has no zero-liquidity guard
/// (Pool.sol:344-368 — `computeSwapStep` with `liquidity == 0` returns amountIn/amountOut/fee all 0
/// and advances the price to the target for free).
contract RedTeamT5Sentinel is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal pm;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;

    address internal lp = address(0xABCD);
    address internal trader = address(0xB07);

    function setUp() public {
        pm = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        swapRouter = new PoolSwapTest(IPoolManager(address(pm)));
        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Liquidity ONLY far above the current price: a gap sits between spot and tick 1000.
        MockERC20(Currency.unwrap(c0)).mint(lp, 1e30);
        MockERC20(Currency.unwrap(c1)).mint(lp, 1e30);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 1000, tickUpper: 2000, liquidityDelta: 1_000e18, salt: 0}), ""
        );
        vm.stopPrank();

        MockERC20(Currency.unwrap(c0)).mint(trader, 1e30);
        MockERC20(Currency.unwrap(c1)).mint(trader, 1e30);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_T5d_exactInSwapCanRealizeZeroInputWhileMovingThePrice() public {
        (, int24 before,,) = IPoolManager(address(pm)).getSlot0(key.toId());

        vm.prank(trader);
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(100e18), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(500)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (, int24 after_,,) = IPoolManager(address(pm)).getSlot0(key.toId());
        console2.log("--- T5d: a real exact-in swap with a ZERO realized input ---");
        console2.log("  tick before        ", int256(before));
        console2.log("  tick after         ", int256(after_));
        console2.log("  realized amount0   ", int256(d.amount0()));
        console2.log("  realized amount1   ", int256(d.amount1()));

        assertEq(d.amount1(), int128(0), "input leg realized zero");
        assertEq(d.amount0(), int128(0), "output leg realized zero");
        assertGt(after_, before, "yet the pool price moved");
        // Fed to `_guardSwap` as `(amountIn = 0, amountOut = 0)` this is exactly the spot sentinel.
    }
}
