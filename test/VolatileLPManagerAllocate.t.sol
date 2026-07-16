// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice VolatileLPManager.allocate: per-call ranges, salt-keyed multi-position, amountMax + minOut.
contract VolatileLPManagerAllocateTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
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

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolId = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0)); // 1:1
        _seedPool();

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));

        BaseLPManager.PoolConfig[] memory cfgs = new BaseLPManager.PoolConfig[](1);
        cfgs[0] = BaseLPManager.PoolConfig({key: key, tickLower: -60, tickUpper: 60}); // config range unused by volatile
        mgr.initialize(BaseLPManager.InitParams({owner: owner, name: bytes32("Vol"), pools: cfgs}));

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

    function _leg(bytes32 salt, int24 tl, int24 tu, uint256 amt, uint128 max0, uint128 max1)
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
            minLiquidity: 0,
            amount0Max: max0,
            amount1Max: max1
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
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18, type(uint128).max, type(uint128).max)));

        V4PositionManager.Position memory p = mgr.positionOf(salt);
        assertGt(p.liquidity, 0, "liquidity");
        assertEq(p.tickLower, int24(-60), "tickLower");
        assertEq(p.tickUpper, int24(60), "tickUpper");
        assertEq(mgr.openPositionCount(), 1, "count");
    }

    function test_allocate_multiPositionPerPool() public {
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(bytes32(uint256(1)), -60, 60, 100e18, type(uint128).max, type(uint128).max)));
        mgr.allocate(_one(_leg(bytes32(uint256(2)), -120, 120, 100e18, type(uint128).max, type(uint128).max)));
        vm.stopPrank();

        assertEq(mgr.openPositionCount(), 2, "two positions in one pool");
        assertEq(mgr.positionOf(bytes32(uint256(2))).tickLower, int24(-120), "second range");
    }

    function test_allocate_amountMaxExceeded_reverts() public {
        // amount0Max = 1 wei is far below the owed for a 100e18-sized add ⇒ revert.
        vm.prank(owner);
        vm.expectRevert();
        mgr.allocate(_one(_leg(bytes32(uint256(1)), -60, 60, 100e18, 1, type(uint128).max)));
    }

    function test_allocate_rangeMismatch_reverts() public {
        bytes32 salt = bytes32(uint256(7));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18, type(uint128).max, type(uint128).max)));
        // top up the same salt at a different range ⇒ RangeMismatch
        vm.expectRevert(abi.encodeWithSelector(VolatileLPManager.RangeMismatch.selector, salt));
        mgr.allocate(_one(_leg(salt, -120, 120, 50e18, type(uint128).max, type(uint128).max)));
        vm.stopPrank();
    }

    function test_allocate_preSwap_minAmountOut_reverts() public {
        VolatileLPManager.VolatileAllocLeg memory l =
            _leg(bytes32(uint256(1)), -60, 60, 10e18, type(uint128).max, type(uint128).max);
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
            minLiquidity: 0,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
    }

    function test_recenter_movesRange() public {
        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18, type(uint128).max, type(uint128).max)));
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
        mgr.allocate(_one(_leg(salt, -60, 60, 100e18, type(uint128).max, type(uint128).max)));
        VolatileLPManager.RecenterParams memory rp = _recenter(salt, -120, 120);
        rp.zeroForOne = true;
        rp.swapAmountIn = 5e18;
        rp.swapPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        mgr.recenter(rp);
        vm.stopPrank();

        assertEq(mgr.positionOf(salt).tickLower, int24(-120), "moved");
        assertGt(mgr.positionOf(salt).liquidity, 0, "re-added after rebalance");
    }

    function test_recenter_unknownPosition_reverts() public {
        bytes32 salt = bytes32(uint256(99));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, salt));
        mgr.recenter(_recenter(salt, -120, 120));
    }
}
