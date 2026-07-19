// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {MockERC20, MockPriceOracle} from "./helpers/Mocks.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Audit M-VOL-2 remediation for StableLPManager: an operator-triggered swap (allocate pre-swap /
/// reinvest swap) is allowed only when the price oracle vouches for it (fail-closed); the NFT owner keeps
/// full freedom. Same owner/operator-asymmetric guard as the Volatile product, now shared from
/// BaseLPManager. Stable's exposure is idle+fees (no operator-callable principal-removal path), but the
/// guard applies uniformly.
contract StableLPManagerOperatorSwapGuardTest is StableLPTestBase {
    MockPriceOracle internal oracle;
    PoolSwapTest internal swapRouter;

    uint8 internal constant P = 0; // pool under test

    function setUp() public override {
        super.setUp();
        oracle = new MockPriceOracle();
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        // Extra idle USDT for reinvest/allocate swaps; open a position per pool as owner (owner bypasses).
        MockERC20(Currency.unwrap(USDT)).mint(address(mgr), 3 * FUND);
        vm.startPrank(owner);
        mgr.allocate(_allocateParams(FUND));
        mgr.setOperator(bot, true);
        vm.stopPrank();
    }

    /// @dev Trade both directions through pool P so the manager's in-range [-60,60] position accrues fees
    /// on BOTH currencies (so a later `reinvest` has something to compound ⇒ L > 0).
    function _accrueFees() internal {
        address trader = address(0x7EA4E5);
        MockERC20(Currency.unwrap(USDT)).mint(trader, 1_000e18);
        MockERC20(Currency.unwrap(pairOf[P])).mint(trader, 1_000e18);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(USDT)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(pairOf[P])).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            swapRouter.swap(
                poolKeys[P],
                SwapParams({
                    zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ts,
                ""
            );
            swapRouter.swap(
                poolKeys[P],
                SwapParams({
                    zeroForOne: false, amountSpecified: -100e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ts,
                ""
            );
        }
        vm.stopPrank();
    }

    /// @dev A single-leg allocate whose pre-swap converts USDT into the pair token of pool `P`.
    function _swapLeg() internal view returns (BaseLPManager.AllocLeg[] memory legs) {
        bool quoteIsZero = Currency.unwrap(poolKeys[P].currency0) == Currency.unwrap(USDT);
        uint160 limit = quoteIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: poolKeys[P].toId(),
            zeroForOne: quoteIsZero,
            swapAmountIn: 100e18,
            swapPriceLimit: limit,
            amount0Desired: 40e18,
            amount1Desired: 40e18,
            minLiquidity: 0
        });
    }

    function _reinvestLeg() internal view returns (BaseLPManager.AllocLeg memory leg) {
        leg = _swapLeg()[0];
    }

    function _poolId() internal view returns (PoolId) {
        return poolKeys[P].toId();
    }

    // ────────── operator allocate pre-swap ──────────

    function test_operatorAllocateSwap_noOracle_reverts() public {
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.allocate(_swapLeg());
    }

    function test_operatorAllocateSwap_notEnforced_reverts() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle)); // default: NotEnforced
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapUnverified.selector, _poolId()));
        mgr.allocate(_swapLeg());
    }

    function test_operatorAllocateSwap_outOfBounds_reverts() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Revert);
        vm.prank(bot);
        vm.expectRevert(MockPriceOracle.MockPriceOutOfBounds.selector);
        mgr.allocate(_swapLeg());
    }

    function test_operatorAllocateSwap_inBounds_succeeds() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Pass);
        vm.prank(bot);
        mgr.allocate(_swapLeg()); // vouched ⇒ allowed
        assertGt(mgr.positionOf(_saltFor(P)).liquidity, 0, "operator allocate applied under a vouching oracle");
    }

    // ────────── operator reinvest swap ──────────

    function test_operatorReinvestSwap_noOracle_reverts() public {
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.reinvest(_reinvestLeg());
    }

    function test_operatorReinvestSwap_inBounds_succeeds() public {
        _accrueFees(); // real two-sided fees to compound (else reinvest is a no-op ⇒ ZeroLiquidity)
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Pass);

        uint128 before = mgr.positionOf(_saltFor(P)).liquidity;
        BaseLPManager.AllocLeg memory leg = _reinvestLeg();
        leg.swapAmountIn = 1e6; // tiny balancing swap, far below the accrued fees (keeps both sides positive)
        vm.prank(bot);
        mgr.reinvest(leg); // vouched ⇒ allowed; compounds fees ⇒ L > 0
        assertGt(mgr.positionOf(_saltFor(P)).liquidity, before, "reinvest compounded fees under a vouching oracle");
    }

    // ────────── owner: full freedom ──────────

    function test_ownerAllocateSwap_noOracle_succeeds() public {
        vm.prank(owner);
        mgr.allocate(_swapLeg()); // owner bypasses the operator guard
    }

    // ────────── operator: swapless allocate stays unrestricted ──────────

    function test_operatorSwaplessAllocate_noOracle_succeeds() public {
        // Fund both sides so a no-swap add settles; the leg carries swapAmountIn == 0 ⇒ no guard.
        MockERC20(Currency.unwrap(poolKeys[P].currency0)).mint(address(mgr), 100e18);
        MockERC20(Currency.unwrap(poolKeys[P].currency1)).mint(address(mgr), 100e18);
        BaseLPManager.AllocLeg[] memory legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: poolKeys[P].toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: 10e18,
            amount1Desired: 10e18,
            minLiquidity: 0
        });
        vm.prank(bot);
        mgr.allocate(legs); // no swap ⇒ operator allowed without an oracle
    }
}
