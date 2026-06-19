// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Protocol fee = 10% of every realized fee accrual, skimmed to the immutable treasury on
/// claimFees / reinvest / withdrawTo. Generates bidirectional volume on pool 0 (USDC/USDT) so both
/// currencies accrue fees.
contract StableLPManagerProtocolFeeTest is StableLPTestBase {
    PoolSwapTest internal swapRouter;
    address internal trader = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(USDT)).mint(trader, FUND);
        MockERC20(Currency.unwrap(USDC)).mint(trader, FUND);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(USDT)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(USDC)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Bidirectional volume through pool 0 → fees accrue on both currencies.
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

    // ────────── claimFees ──────────

    function test_claimFees_skims10PercentToTreasury() public {
        uint256 tBefore = _bal(USDC, treasury);
        uint256 mBefore = _bal(USDC, address(mgr));

        vm.prank(owner);
        mgr.claimFees(_saltFor(0));

        uint256 tGain = _bal(USDC, treasury) - tBefore;
        uint256 mGain = _bal(USDC, address(mgr)) - mBefore;
        assertGt(tGain, 0, "treasury received a fee");
        // manager ~90%, treasury ~10% ⇒ manager == 9 * treasury (within rounding).
        assertApproxEqRel(mGain, tGain * 9, 0.01e18, "90/10 split");
    }

    // ────────── reinvest ──────────

    function test_reinvest_skimsToTreasury() public {
        uint256 tUSDCBefore = _bal(USDC, treasury);
        uint256 tUSDTBefore = _bal(USDT, treasury);

        StableLPManager.AllocLeg memory leg = StableLPManager.AllocLeg({
            poolId: poolKeys[0].toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: 0,
            amount1Desired: 0,
            minLiquidity: 0,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        vm.prank(owner);
        mgr.reinvest(leg);

        // The realized fees were skimmed before compounding ⇒ treasury balance grew.
        assertGt(
            (_bal(USDC, treasury) - tUSDCBefore) + (_bal(USDT, treasury) - tUSDTBefore), 0, "treasury got reinvest fee"
        );
    }

    // ────────── withdrawTo ──────────

    function test_withdrawTo_skimsFeeComponentToTreasury() public {
        uint256 tUSDCBefore = _bal(USDC, treasury);
        uint256 tUSDTBefore = _bal(USDT, treasury);

        // Pull pool 0 (USDC/USDT) fully and deliver a little USDC to a recipient.
        StableLPManager.WithdrawStep[] memory pulls = new StableLPManager.WithdrawStep[](1);
        pulls[0] = StableLPManager.WithdrawStep({
            poolId: poolKeys[0].toId(), liquidityToPull: mgr.positionOf(_saltFor(0)).liquidity
        });
        StableLPManager.WithdrawSwap[] memory swaps = new StableLPManager.WithdrawSwap[](0);

        vm.prank(owner);
        mgr.withdrawTo(
            StableLPManager.WithdrawToParams({
                recipient: address(0xBEEF),
                requestedStable: USDC,
                amount: 1e18,
                pulls: pulls,
                swaps: swaps,
                reinvestRemainder: false
            })
        );

        assertGt(
            (_bal(USDC, treasury) - tUSDCBefore) + (_bal(USDT, treasury) - tUSDTBefore), 0, "treasury got withdraw fee"
        );
    }

    // ────────── constructor ──────────

    function test_constructor_zeroTreasury_reverts() public {
        vm.expectRevert(StableLPManager.ZeroTreasury.selector);
        new StableLPManager(IPoolManager(address(poolManager)), address(0));
    }
}
