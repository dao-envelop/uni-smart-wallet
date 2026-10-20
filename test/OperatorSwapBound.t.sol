// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice task_060 — operator round-trip drain (audit 2026-10-20, HIGH). The oracle judged each swap
/// alone and settlement is net, so an operator acting as a JIT LP in a configured pool could make the
/// manager swap a notional far above its book out and straight back inside one op: every swap passed
/// the real ChainlinkPriceOracle and the manager paid ~2·fee·notional to the operator's liquidity.
/// Before the fix: `test_bridgeRoundTrip` took the manager from 20e18 to 14.0e18, the allocate variant
/// (also on prod v2.1.0) from 20e18 to 15.8e18. Now an operator swap may spend only what the manager
/// holds and may not reverse an earlier swap of the same op; the owner is unbounded.
contract OperatorSwapBoundTest is RedTeamBase {
    bytes32 constant SALT2 = bytes32(uint256(2));
    bytes32 constant SALT3 = bytes32(uint256(3));
    uint256 constant JIT_L = 1e24;

    function setUp() public {
        _boot(3000, 60, 1e20, 10e18, 10e18);
        _openAsOwner(-600, 600, 5e18);
        vm.startPrank(bot);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The operator's own concentrated liquidity at the current price: it earns the pool fee the
    /// manager pays (and makes the pool deep enough for the oracle to pass the swaps).
    function _jit(int256 d) internal {
        vm.prank(bot);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: d, salt: bytes32("jit")}), ""
        );
    }

    function _swapLeg(bytes32 salt, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (VolatileLPManager.VolatileAllocLeg memory leg)
    {
        leg = _leg(salt, -60, 60, 1e15, 1e15);
        leg.zeroForOne = zeroForOne;
        leg.swapAmountIn = amountIn;
        leg.swapPriceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _bridge(bool zeroForOne, uint256 amountIn) internal view returns (VolatileLPManager.BridgeSwap memory) {
        return VolatileLPManager.BridgeSwap({
            poolId: pid,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            priceLimit: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            minOut: 0
        });
    }

    function _twoLegs(VolatileLPManager.VolatileAllocLeg memory a, VolatileLPManager.VolatileAllocLeg memory b)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        legs = new VolatileLPManager.VolatileAllocLeg[](2);
        legs[0] = a;
        legs[1] = b;
    }

    // ────────── the audit PoCs, now reverting ──────────

    /// @dev PoC v2.2: bridge 1000e18 X→Y, add-leg pre-swap 995.5e18 Y→X, manager book 20e18.
    function test_bridgeRoundTrip_aboveHoldings_reverts() public {
        _jit(int256(JIT_L));
        uint256 a = 1000e18;
        uint128 liq = mgr.positionOf(SALT).liquidity;
        VolatileLPManager.VolatileAllocLeg memory add = _swapLeg(SALT2, false, (a * 9955) / 10000);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapExceedsHoldings.selector, c0));
        mgr.moveLiquidity(SALT, liq, add, _bridge(true, a));
    }

    /// @dev PoC on prod v2.1.0: two allocate legs in the same pool, 700e18 X→Y then back.
    function test_allocateRoundTrip_aboveHoldings_reverts() public {
        _jit(int256(JIT_L));
        uint256 a = 700e18;
        VolatileLPManager.VolatileAllocLeg[] memory legs =
            _twoLegs(_swapLeg(SALT2, true, a), _swapLeg(SALT3, false, (a * 9955) / 10000));
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapExceedsHoldings.selector, c0));
        _allocateAs(bot, legs);
    }

    /// @dev Within holdings the round trip is still refused: it moves nothing and pays the fee twice.
    function test_allocateRoundTrip_withinHoldings_reverts() public {
        _jit(int256(JIT_L));
        VolatileLPManager.VolatileAllocLeg[] memory legs =
            _twoLegs(_swapLeg(SALT2, true, 1e18), _swapLeg(SALT3, false, 1e18));
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapRoundTrip.selector, c0));
        _allocateAs(bot, legs);
    }

    function test_moveRoundTrip_withinHoldings_reverts() public {
        _jit(int256(JIT_L));
        uint128 liq = mgr.positionOf(SALT).liquidity;
        VolatileLPManager.VolatileAllocLeg memory add = _swapLeg(SALT2, false, 1e18);
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapRoundTrip.selector, c0));
        mgr.moveLiquidity(SALT, liq, add, _bridge(true, 1e18));
    }

    // ────────── what stays allowed ──────────

    function test_operatorSingleSwapWithinHoldings_succeeds() public {
        _jit(int256(JIT_L));
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _swapLeg(SALT2, true, 1e18);
        _allocateAs(bot, legs);
        assertGt(mgr.positionOf(SALT2).liquidity, 0, "operator swap within holdings applied");
    }

    /// @dev Same direction twice is not a round trip.
    function test_operatorSameDirectionTwice_succeeds() public {
        _jit(int256(JIT_L));
        _allocateAs(bot, _twoLegs(_swapLeg(SALT2, true, 1e18), _swapLeg(SALT3, true, 1e18)));
        assertGt(mgr.positionOf(SALT3).liquidity, 0, "second same-direction leg applied");
    }

    /// @dev Liquidity pulled in the same op is the manager's: idle X is ~5e18, the bridge spends 7e18.
    function test_operatorMoveBridge_spendsPulledLiquidity_succeeds() public {
        _jit(int256(JIT_L));
        uint256 idle0 = MockERC20(Currency.unwrap(c0)).balanceOf(address(mgr));
        uint256 a = idle0 + 2e18;
        uint128 liq = mgr.positionOf(SALT).liquidity;
        vm.prank(bot);
        mgr.moveLiquidity(SALT, liq, _leg(SALT2, -60, 60, 1e18, 1e18), _bridge(true, a));
        assertEq(mgr.positionOf(SALT).liquidity, 0, "source pulled");
        assertGt(mgr.positionOf(SALT2).liquidity, 0, "target added");
    }

    function test_operatorMoveBridge_aboveHoldingsPlusPulled_reverts() public {
        _jit(int256(JIT_L));
        uint128 liq = mgr.positionOf(SALT).liquidity;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapExceedsHoldings.selector, c0));
        mgr.moveLiquidity(SALT, liq, _leg(SALT2, -60, 60, 1e15, 1e15), _bridge(true, 12e18));
    }

    /// @dev The owner keeps full freedom, round trip above holdings included.
    function test_ownerRoundTripAboveHoldings_succeeds() public {
        _jit(int256(JIT_L));
        uint256 a = 700e18;
        _allocateAs(owner, _twoLegs(_swapLeg(SALT2, true, a), _swapLeg(SALT3, false, (a * 9955) / 10000)));
        assertGt(mgr.positionOf(SALT3).liquidity, 0, "owner round trip applied");
    }
}
