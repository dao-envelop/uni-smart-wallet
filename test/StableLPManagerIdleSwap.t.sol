// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice `withdrawTo` with NO pulls converts idle from one managed currency into another, inside a
/// configured pool, without the money leaving the manager.
///
/// Nothing was added to the contracts for this — it is an existing capability nobody had exercised.
/// Every successful `withdrawTo` in the suite pulls at least one position; the three that pass an
/// empty `pulls` array all revert before `unlock`, so the path below was untested, and "the frontend
/// relies on behaviour we never asserted" is exactly how a refactor removes a feature silently.
///
/// The mechanism, in the contract's own terms:
///   - the pull loop iterates `pulls.length`, so an empty array is simply zero iterations;
///   - a swap runs in `pools[_indexOf(poolId)]`, so both its currencies are necessarily managed;
///   - `_settleManaged` pays the swap's negative delta by transferring the input OUT OF the manager's
///     own balance — that is what makes idle the funding source;
///   - the delta check then sees only the swap's output, so `amount` behaves as a **minAmountOut**;
///   - `_take(requestedCurrency, recipient, amount)` with `recipient == manager` returns it to idle.
///
/// Note it takes no protocol fee: `_skimFees` lives inside `_pullLiquidity`, and there is no pull.
/// That is a pricing decision worth being deliberate about, not an oversight, so it is asserted.
contract StableLPManagerIdleSwapTest is StableLPTestBase {
    /// @dev No allocate in setUp — the base funds the manager with FUND USDT and we keep it idle.
    /// @dev exactIn swap params: sell `amountIn` of `tokenIn` in pool `i`.
    function _exactIn(uint8 i, Currency tokenIn, uint256 amountIn)
        internal
        view
        returns (BaseLPManager.WithdrawSwap memory)
    {
        bool zeroForOne = Currency.unwrap(tokenIn) == Currency.unwrap(poolKeys[i].currency0);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return BaseLPManager.WithdrawSwap({
            poolId: poolKeys[i].toId(),
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn), // negative ⇒ exact input
            sqrtPriceLimitX96: limit
        });
    }

    function _noPulls() internal pure returns (BaseLPManager.WithdrawStep[] memory) {
        return new BaseLPManager.WithdrawStep[](0);
    }

    function _swap(BaseLPManager.WithdrawSwap memory s) internal pure returns (BaseLPManager.WithdrawSwap[] memory a) {
        a = new BaseLPManager.WithdrawSwap[](1);
        a[0] = s;
    }

    /// THE claim: idle USDT becomes idle USDC, no position touched, nothing sent anywhere.
    function test_idleSwap_convertsIdleWithoutLeavingTheManager() public {
        uint256 amountIn = 100e18;
        uint256 minOut = 99e18; // 1:1 pool, 0.30% fee, deep liquidity ⇒ ~99.7 out

        uint256 usdtBefore = _bal(USDT, address(mgr));
        uint256 usdcBefore = _bal(USDC, address(mgr));
        uint256 ownerUSDCBefore = _bal(USDC, owner);

        vm.prank(owner);
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: address(mgr),
                requestedCurrency: USDC,
                amount: minOut,
                pulls: _noPulls(),
                swaps: _swap(_exactIn(0, USDT, amountIn))
            })
        );

        assertEq(_bal(USDT, address(mgr)), usdtBefore - amountIn, "spent exactly the idle it was told to");
        assertGe(_bal(USDC, address(mgr)), usdcBefore + minOut, "received at least the floor");
        assertEq(_bal(USDC, owner), ownerUSDCBefore, "nothing reached the owner");
        // No position exists, and none was created: this path never touches liquidity.
        assertEq(mgr.positionOf(_saltFor(0)).liquidity, 0, "no position touched");
    }

    /// The surplus over `amount` is not stranded in the PoolManager — `_settleManaged` sweeps it back,
    /// so the whole swap output lands as idle. Without this the floor would silently cost the user.
    function test_idleSwap_surplusAboveTheFloorStaysWithTheManager() public {
        uint256 amountIn = 100e18;
        uint256 usdcBefore = _bal(USDC, address(mgr));

        vm.prank(owner);
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: address(mgr),
                requestedCurrency: USDC,
                amount: 1e18, // a deliberately low floor
                pulls: _noPulls(),
                swaps: _swap(_exactIn(0, USDT, amountIn))
            })
        );

        // 0.30% fee on a 1:1 pool: out is a little under the input, and far above the 1e18 floor.
        uint256 received = _bal(USDC, address(mgr)) - usdcBefore;
        assertGt(received, 99e18, "the full swap output landed, not just the floor");
        assertLt(received, amountIn, "and it is net of the pool fee");
    }

    /// `amount` is the slippage bound. Asking for more than the swap can return reverts the whole
    /// transaction — the loud, free failure, with the idle untouched.
    function test_idleSwap_floorAboveWhatTheSwapReturns_reverts() public {
        uint256 usdtBefore = _bal(USDT, address(mgr));

        BaseLPManager.WithdrawToParams memory p = BaseLPManager.WithdrawToParams({
            recipient: address(mgr),
            requestedCurrency: USDC,
            amount: 101e18, // more than 100 USDT can buy at 1:1 minus fee
            pulls: _noPulls(),
            swaps: _swap(_exactIn(0, USDT, 100e18))
        });

        // The error carries both numbers, so the assertion names what the swap actually returned:
        // 100 USDT through a 1:1 pool at 0.30% comes back as 99.69 USDC, and the floor was 101.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseLPManager.AmountNotDelivered.selector, uint256(99_690_060_900_928_177_460), uint256(101e18)
            )
        );
        mgr.withdrawTo(p);

        assertEq(_bal(USDT, address(mgr)), usdtBefore, "nothing moved");
    }

    /// No protocol fee is taken on a conversion: `_skimFees` runs only inside `_pullLiquidity`.
    function test_idleSwap_takesNoProtocolFee() public {
        uint256 treasuryUSDCBefore = _bal(USDC, treasury);
        uint256 treasuryUSDTBefore = _bal(USDT, treasury);

        vm.prank(owner);
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: address(mgr),
                requestedCurrency: USDC,
                amount: 99e18,
                pulls: _noPulls(),
                swaps: _swap(_exactIn(0, USDT, 100e18))
            })
        );

        assertEq(_bal(USDC, treasury), treasuryUSDCBefore, "treasury took nothing in USDC");
        assertEq(_bal(USDT, treasury), treasuryUSDTBefore, "treasury took nothing in USDT");
    }

    /// Owner-only, like every other `withdrawTo`. An operator — or an agent holding an operator key —
    /// cannot convert idle, which is the boundary the product documents.
    function test_idleSwap_byOperator_reverts() public {
        vm.prank(owner);
        mgr.setOperator(bot, true);

        BaseLPManager.WithdrawToParams memory p = BaseLPManager.WithdrawToParams({
            recipient: address(mgr),
            requestedCurrency: USDC,
            amount: 99e18,
            pulls: _noPulls(),
            swaps: _swap(_exactIn(0, USDT, 100e18))
        });

        vm.prank(bot);
        vm.expectRevert(SingletonNFTOwned.NotOwnerNFT.selector);
        mgr.withdrawTo(p);
    }

    /// Spending more idle than the manager holds fails on the settle transfer rather than half-doing
    /// the conversion.
    function test_idleSwap_moreThanIdle_reverts() public {
        BaseLPManager.WithdrawToParams memory p = BaseLPManager.WithdrawToParams({
            recipient: address(mgr),
            requestedCurrency: USDC,
            amount: 1e18,
            pulls: _noPulls(),
            swaps: _swap(_exactIn(0, USDT, FUND + 1e18))
        });

        vm.prank(owner);
        vm.expectRevert();
        mgr.withdrawTo(p);
    }
}
