// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract StableLPManagerReinvestTest is StableLPTestBase {
    PoolSwapTest internal swapRouter;
    address internal trader = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        for (uint8 i = 0; i < 3; ++i) {
            MockERC20(Currency.unwrap(poolKeys[i].currency0)).mint(trader, FUND);
            MockERC20(Currency.unwrap(poolKeys[i].currency1)).mint(trader, FUND);
        }
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(USDT)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(USDC)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(DAI)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(USDe)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Generate bidirectional fee volume through pool 0 (USDC/USDT) within the manager's range.
        for (uint256 k = 0; k < 4; ++k) {
            _swap(0, true, 5e18);
            _swap(0, false, 5e18);
        }
    }

    function _swap(uint8 i, bool zeroForOne, int256 amountIn) internal {
        vm.prank(trader);
        swapRouter.swap(
            poolKeys[i],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_claimFees_collectsToManager() public {
        uint256 before = _bal(USDC, address(mgr)) + _bal(USDT, address(mgr));

        vm.prank(owner);
        mgr.claimFees(_saltFor(0));

        uint256 afterBal = _bal(USDC, address(mgr)) + _bal(USDT, address(mgr));
        assertGt(afterBal, before, "fees collected to manager");
        // Principal untouched: the position is still open with the same liquidity.
        assertGt(mgr.positionOf(_saltFor(0)).liquidity, 0);
    }

    function test_reinvest_compoundsRealizedFees() public {
        uint128 liqBefore = mgr.positionOf(_saltFor(0)).liquidity;

        BaseLPManager.AllocLeg memory leg = BaseLPManager.AllocLeg({
            poolId: poolKeys[0].toId(),
            zeroForOne: false,
            swapAmountIn: 0, // fees already span both sides (bidirectional volume)
            swapPriceLimit: 0,
            amount0Desired: 0, // reinvest sizes the add from realized fee deltas, not these
            amount1Desired: 0,
            minLiquidity: 0
        });

        vm.prank(owner);
        mgr.reinvest(leg);

        assertGt(mgr.positionOf(_saltFor(0)).liquidity, liqBefore, "liquidity compounded from realized fees");
    }

    function test_claimFees_byOperator_succeeds() public {
        vm.prank(owner);
        mgr.setOperator(bot, true);
        vm.prank(bot);
        mgr.claimFees(_saltFor(0)); // operator may harvest (value stays in manager)
    }
}
