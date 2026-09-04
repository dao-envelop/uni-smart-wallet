// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Every path that realizes fees must say how much it realized (task_047, finding
/// `2026-08-22-recenter-erases-lifetime-fees`).
///
/// In v4 ANY `modifyLiquidity` hands back what the position accrued — not only the `liquidityDelta == 0`
/// call. So fees are realized on five paths: explicit claim, a top-up of an already-open position,
/// `reinvest`, `recenter` and `withdraw`. `FeesCollected` used to be emitted on the first only, which is
/// why lifetime fees read as zero for any position an operator loop had touched, and for every closed
/// position. The event now lives in `BaseLPManager._skimFees`, the one point all five go through.
///
/// This suite covers the four paths a Stable manager can reach; `recenter` is Volatile-only and is
/// covered in `VolatileLPManagerAllocate.t.sol`, `moveLiquidity` in `VolatileLPManagerMove.t.sol`.
contract FeeRealisationEventsTest is StableLPTestBase {
    PoolSwapTest internal swapRouter;
    address internal trader = address(0x77ADE);

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(USDT)).mint(trader, 10_000e18);
        MockERC20(Currency.unwrap(USDC)).mint(trader, 10_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(USDT)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(USDC)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ────────── path 1: explicit claim ──────────

    /// The path that always reported. What matters here is that it reports exactly ONCE: the two
    /// explicit emits in `_handleClaim` were removed when the event moved into `_skimFees`, and a
    /// duplicate would double every lifetime-fee counter downstream.
    function test_claim_reportsOnce_notTwice() public {
        _allocateAll();
        _tradeToAccrueFees();

        vm.recordLogs();
        vm.prank(owner);
        mgr.claimFees(_saltFor(0));

        (uint256 seen, uint256 f0, uint256 f1) = _feesReported(_saltFor(0));
        assertEq(seen, 1, "claim announces its fees exactly once");
        assertTrue(f0 > 0 || f1 > 0, "and the amount is real");
    }

    // ────────── path 2: top-up of an open position ──────────

    /// The one that is not operator exotica but an ordinary `allocate`: a position that has been
    /// collecting fees for a week hands them over silently the moment anything is added to it.
    function test_allocateIntoOpenPosition_reportsRealisedFees() public {
        _allocateAll();
        _tradeToAccrueFees();

        // Top up pool 0 only, out of the manager's remaining idle balance.
        BaseLPManager.AllocLeg[] memory legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = _topUpLeg(0, 1e18);

        vm.recordLogs();
        vm.prank(owner);
        mgr.allocate(legs);

        (uint256 seen, uint256 f0, uint256 f1) = _feesReported(_saltFor(0));
        assertEq(seen, 1, "the top-up announced what it realized");
        assertTrue(f0 > 0 || f1 > 0, "non-zero");
    }

    // ────────── path 3: reinvest (Stable only) ──────────

    function test_reinvest_reportsRealisedFees() public {
        _allocateAll();
        _tradeToAccrueFees();

        BaseLPManager.AllocLeg[] memory legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = _topUpLeg(0, 0);

        vm.recordLogs();
        vm.prank(owner);
        mgr.reinvest(legs[0]);

        (uint256 seen, uint256 f0, uint256 f1) = _feesReported(_saltFor(0));
        // Reinvest realizes on the old position, then adds back into it — the add itself finds nothing
        // accrued, so the zero guard keeps that second `_skimFees` silent.
        assertEq(seen, 1, "reinvest announces the compounded fees once, not twice");
        assertTrue(f0 > 0 || f1 > 0, "non-zero");
    }

    // ────────── path 5: withdraw ──────────

    /// The path that explains why closed positions report zero for their whole life: `_pullLiquidity`
    /// realizes, skims, decrements and — when the position empties — deletes the record.
    function test_withdraw_reportsRealisedFees_evenWhenItClosesThePosition() public {
        _allocateAll();
        _tradeToAccrueFees();

        bytes32 salt = _saltFor(0);
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: mgr.positionOf(salt).liquidity});

        vm.recordLogs();
        vm.prank(owner);
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: owner,
                requestedCurrency: USDT,
                amount: 1e18,
                pulls: pulls,
                swaps: new BaseLPManager.WithdrawSwap[](0)
            })
        );

        (uint256 seen, uint256 f0, uint256 f1) = _feesReported(salt);
        assertEq(seen, 1, "the closing pull announced the lifetime it was erasing");
        assertTrue(f0 > 0 || f1 > 0, "non-zero");
        assertEq(mgr.positionOf(salt).liquidity, 0, "and the position is indeed gone");
    }

    // ────────── the zero guard ──────────

    /// A fresh position has nothing to report, and an empty `FeesCollected` is indistinguishable from a
    /// real collection of zero for anything reading the logs.
    function test_freshAllocate_emitsNoFeeEvent() public {
        vm.recordLogs();
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));

        for (uint8 i = 0; i < 3; ++i) {
            (uint256 seen,,) = _feesReported(_saltFor(i));
            assertEq(seen, 0, "nothing accrued yet, nothing announced");
        }
    }

    // ────────── helpers ──────────

    function _allocateAll() internal {
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND / 2));
    }

    /// @dev An add into pool `i` with no pre-swap, sized from whatever idle the manager still holds.
    function _topUpLeg(uint8 i, uint256 amt) internal view returns (BaseLPManager.AllocLeg memory) {
        return BaseLPManager.AllocLeg({
            poolId: poolKeys[i].toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    /// @dev A trader round-trips through pool 0 so the manager's in-range position accrues on both sides.
    function _tradeToAccrueFees() internal {
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.startPrank(trader);
        swapRouter.swap(
            poolKeys[0],
            SwapParams({zeroForOne: true, amountSpecified: -5e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );
        swapRouter.swap(
            poolKeys[0],
            SwapParams({zeroForOne: false, amountSpecified: -5e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ts,
            ""
        );
        vm.stopPrank();
    }

    /// @dev How many `FeesCollected` this manager emitted for `salt`, and the amounts of the last one.
    function _feesReported(bytes32 salt) internal returns (uint256 seen, uint256 fees0, uint256 fees1) {
        bytes32 topic = keccak256("FeesCollected(bytes32,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(mgr) && logs[i].topics[0] == topic && logs[i].topics[1] == salt) {
                ++seen;
                (fees0, fees1) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }
}
