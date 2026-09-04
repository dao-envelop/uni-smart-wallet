// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice VolatileLPManager.allocate: per-call ranges, salt-keyed multi-position, minLiquidity + minOut.
contract VolatileLPManagerAllocateTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    VolatileLPManager internal mgr;

    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    uint256 internal constant FUND = 1_000e18;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolId = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0)); // 1:1
        _seedPool();

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));

        PoolKey[] memory cfgs = new PoolKey[](1); // volatile config is keys only — ranges are per-call
        cfgs[0] = key;
        mgr.initialize(
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
        );

        MockERC20(Currency.unwrap(c0)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), FUND);
    }

    function _seedPool() internal {
        uint256 amt = 2_000_000e18;
        MockERC20(Currency.unwrap(c0)).mint(lp, amt);
        MockERC20(Currency.unwrap(c1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function _leg(bytes32 salt, int24 tl, int24 tu, uint256 amt)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg memory)
    {
        return VolatileLPManager.VolatileAllocLeg({
            poolId: PoolId.wrap(bytes32(0)), // set by caller
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

    function _one(VolatileLPManager.VolatileAllocLeg memory l)
        internal
        view
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        l.poolId = poolId;
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = l;
    }

    function test_allocate_opensPosition() public {
        bytes32 salt = bytes32(uint256(1));
        vm.prank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18)));

        V4PositionManager.Position memory p = mgr.positionOf(salt);
        assertGt(p.liquidity, 0, "liquidity");
        assertEq(p.tickLower, int24(-60), "tickLower");
        assertEq(p.tickUpper, int24(60), "tickUpper");
        assertEq(mgr.openPositionCount(), 1, "count");
    }

    function test_allocate_multiPositionPerPool() public {
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(bytes32(uint256(1)), -60, 60, 100e18)));
        mgr.allocate(_one(_leg(bytes32(uint256(2)), -120, 120, 100e18)));
        vm.stopPrank();

        assertEq(mgr.openPositionCount(), 2, "two positions in one pool");
        assertEq(mgr.positionOf(bytes32(uint256(2))).tickLower, int24(-120), "second range");
    }

    function test_allocate_zeroLiquidity_reverts() public {
        // Zero desired amounts + minLiquidity 0 ⇒ L == 0. Rejected (audit L-REG-1: no ghost salt).
        vm.prank(owner);
        vm.expectRevert(V4PositionManager.ZeroLiquidity.selector);
        mgr.allocate(_one(_leg(bytes32(uint256(1)), -60, 60, 0)));
        assertEq(mgr.openPositionCount(), 0, "no ghost position registered");
    }

    function test_allocate_minLiquidityNotMet_reverts() public {
        // minLiquidity floored at uint128.max is far above the L a 100e18-sized add yields ⇒ revert.
        // (There is no amount*Max cap: L is sized from desired amounts, so owed ≤ desired by
        // construction; minLiquidity is the add's slippage guard.)
        VolatileLPManager.VolatileAllocLeg memory l = _leg(bytes32(uint256(1)), -60, 60, 100e18);
        l.minLiquidity = type(uint128).max;
        vm.prank(owner);
        vm.expectPartialRevert(BaseLPManager.MinLiquidityNotMet.selector);
        mgr.allocate(_one(l));
    }

    function test_allocate_rangeMismatch_reverts() public {
        bytes32 salt = bytes32(uint256(7));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18)));
        // top up the same salt at a different range ⇒ RangeMismatch
        vm.expectRevert(abi.encodeWithSelector(VolatileLPManager.RangeMismatch.selector, salt));
        mgr.allocate(_one(_leg(salt, -120, 120, 50e18)));
        vm.stopPrank();
    }

    function test_allocate_preSwap_minAmountOut_reverts() public {
        VolatileLPManager.VolatileAllocLeg memory l = _leg(bytes32(uint256(1)), -60, 60, 10e18);
        l.zeroForOne = true;
        l.swapAmountIn = 10e18;
        l.swapPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        l.minAmountOut = 1_000_000e18; // absurd floor ⇒ SwapMinOut
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VolatileLPManager.SwapMinOut.selector, poolId));
        mgr.allocate(_one(l));
    }

    // ────────── recenter ──────────

    function _recenter(bytes32 salt, int24 tl, int24 tu)
        internal
        pure
        returns (VolatileLPManager.RecenterParams memory)
    {
        return VolatileLPManager.RecenterParams({
            salt: salt,
            newTickLower: tl,
            newTickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            minLiquidity: 0
        });
    }

    function test_recenter_movesRange() public {
        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18)));
        mgr.recenter(_recenter(salt, -120, 120));
        vm.stopPrank();

        V4PositionManager.Position memory p = mgr.positionOf(salt);
        assertEq(p.tickLower, int24(-120), "new lower");
        assertEq(p.tickUpper, int24(120), "new upper");
        assertGt(p.liquidity, 0, "re-added");
        assertEq(mgr.openPositionCount(), 1, "still one position (same salt)");
    }

    function test_recenter_withRebalanceSwap() public {
        bytes32 salt = bytes32(uint256(3));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18)));
        VolatileLPManager.RecenterParams memory rp = _recenter(salt, -120, 120);
        rp.zeroForOne = true;
        rp.swapAmountIn = 5e18;
        rp.swapPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        mgr.recenter(rp);
        vm.stopPrank();

        assertEq(mgr.positionOf(salt).tickLower, int24(-120), "moved");
        assertGt(mgr.positionOf(salt).liquidity, 0, "re-added after rebalance");
    }

    /// Path 4 of the five that realize fees (task_047). `recenter` pulls the whole position to move it,
    /// which hands back everything it accrued; before the event moved into `_skimFees` this path took the
    /// fees and reported only `Recentered`, with no amounts — so an operator loop reset the position's
    /// lifetime earnings on every run.
    function test_recenter_reportsRealisedFees() public {
        bytes32 salt = bytes32(uint256(7));
        vm.prank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 500e18)));
        _tradeToAccrueFees();

        vm.recordLogs();
        vm.prank(owner);
        mgr.recenter(_recenter(salt, -120, 120));

        bytes32 topic = keccak256("FeesCollected(bytes32,uint256,uint256)");
        uint256 seen;
        uint256 f0;
        uint256 f1;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(mgr) && logs[i].topics[0] == topic && logs[i].topics[1] == salt) {
                ++seen;
                (f0, f1) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        // Once, not twice: recenter calls `_skimFees` a second time when it re-adds at the new range,
        // where nothing has accrued — the zero guard keeps that one silent.
        assertEq(seen, 1, "recenter announced the fees it realized, exactly once");
        assertTrue(f0 > 0 || f1 > 0, "and the amount is real");
    }

    function test_recenter_unknownPosition_reverts() public {
        bytes32 salt = bytes32(uint256(99));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, salt));
        mgr.recenter(_recenter(salt, -120, 120));
    }

    // ────────── claimFees ──────────

    /// @dev A trader round-trips through the pool near tick 0 so the manager's in-range position
    /// accrues fees on both sides.
    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _tradeToAccrueFees() internal {
        address trader = address(0x7EA4E5);
        MockERC20(Currency.unwrap(c0)).mint(trader, 100e18);
        MockERC20(Currency.unwrap(c1)).mint(trader, 100e18);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ts,
            ""
        );
        vm.stopPrank();
    }

    function test_claimFees_afterSwaps_harvestsToManager() public {
        bytes32 salt = bytes32(uint256(1));
        vm.prank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 500e18)));

        _tradeToAccrueFees();

        uint256 before = _bal(c0, address(mgr)) + _bal(c1, address(mgr));
        vm.prank(owner);
        mgr.claimFees(salt);
        assertGt(_bal(c0, address(mgr)) + _bal(c1, address(mgr)), before, "fees harvested to manager");
    }

    function test_claimFees_unknownPosition_reverts() public {
        bytes32 salt = bytes32(uint256(42));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, salt));
        mgr.claimFees(salt);
    }

    // ────────── withdrawTo ──────────

    function _withdraw(bytes32 salt, uint128 liq, Currency requested, uint256 amount)
        internal
        pure
        returns (BaseLPManager.WithdrawToParams memory p)
    {
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: liq});
        p = BaseLPManager.WithdrawToParams({
            recipient: address(0xCAFE),
            requestedCurrency: requested,
            amount: amount,
            pulls: pulls,
            swaps: new BaseLPManager.WithdrawSwap[](0)
        });
    }

    function test_withdrawTo_deliversToRecipient() public {
        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18)));
        uint128 liq = mgr.positionOf(salt).liquidity;
        mgr.withdrawTo(_withdraw(salt, liq, c0, 10e18));
        vm.stopPrank();

        assertEq(_bal(c0, address(0xCAFE)), 10e18, "recipient received requested currency");
        assertEq(mgr.positionOf(salt).liquidity, 0, "position fully pulled");
        assertEq(mgr.openPositionCount(), 0, "removed from registry");
    }

    function test_withdrawTo_amountNotDelivered_reverts() public {
        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18)));
        uint128 liq = mgr.positionOf(salt).liquidity;
        // request far more than the pulled position frees ⇒ AmountNotDelivered
        vm.expectPartialRevert(BaseLPManager.AmountNotDelivered.selector);
        mgr.withdrawTo(_withdraw(salt, liq, c0, 1_000_000e18));
        vm.stopPrank();
    }

    function test_withdrawTo_byOperatorForbidden() public {
        // withdrawTo is owner-only (onlyOwnerNFT); an operator must not drain.
        vm.prank(owner);
        mgr.setOperator(bot, true);
        vm.prank(bot);
        vm.expectRevert();
        mgr.withdrawTo(_withdraw(bytes32(uint256(1)), 1, c0, 1));
    }
}
