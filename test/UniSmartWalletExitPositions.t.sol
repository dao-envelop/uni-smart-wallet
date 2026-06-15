// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockERC20} from "./helpers/Mocks.sol";
import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";

contract UniSmartWalletExitPositionsTest is V4WalletTestBase {
    PoolSwapTest internal swapRouter;
    address internal trader = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Fund the trader so swaps can pay; mint both currencies and approve the router.
        MockERC20(Currency.unwrap(currency0)).mint(trader, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 1_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ────────── helpers ──────────

    function _open(bytes32 salt, uint128 liquidity) internal {
        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, liquidity, salt, 0, type(uint128).max, type(uint128).max);
    }

    /// @dev Trader swaps a fixed amount through the wallet's range, generating fees.
    function _swapThroughRange(bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ────────── closePosition ──────────

    function test_closePosition_byNFTOwner_succeeds_returnsCapitalPlusFees() public {
        bytes32 salt = bytes32(uint256(1));
        _open(salt, 1e18);

        uint256 walletBal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(wallet));
        uint256 walletBal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(wallet));

        // Two swaps in opposite directions → fees accrue on both sides.
        _swapThroughRange(true, -1e15);
        _swapThroughRange(false, -1e15);

        vm.prank(owner);
        wallet.closePosition(salt);

        // Position is gone from the registry.
        assertEq(wallet.openPositionCount(), 0);
        assertEq(wallet.positionOf(salt).liquidity, 0);

        // Wallet got at least its principal back plus some fees on both sides.
        uint256 walletBal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(wallet));
        uint256 walletBal1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(wallet));
        assertGt(walletBal0After, walletBal0Before, "fees0 not credited");
        assertGt(walletBal1After, walletBal1Before, "fees1 not credited");
    }

    function test_closePosition_byOperator_succeeds() public {
        bytes32 salt = bytes32(uint256(2));
        _open(salt, 1e18);

        vm.prank(owner);
        wallet.setOperator(bot, true);

        vm.prank(bot);
        wallet.closePosition(salt);

        assertEq(wallet.positionOf(salt).liquidity, 0);
    }

    function test_closePosition_byNonAuthorized_reverts() public {
        bytes32 salt = bytes32(uint256(3));
        _open(salt, 1e18);

        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotAuthorized.selector);
        wallet.closePosition(salt);
    }

    function test_closePosition_unknownSalt_reverts() public {
        bytes32 salt = bytes32(uint256(99));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, salt));
        wallet.closePosition(salt);
    }

    // ────────── decreasePosition ──────────

    function test_decreasePosition_partial_succeeds() public {
        bytes32 salt = bytes32(uint256(10));
        _open(salt, 1e18);

        vm.prank(owner);
        wallet.decreasePosition(salt, 4e17);

        V4PositionManager.Position memory p = wallet.positionOf(salt);
        assertEq(p.liquidity, 6e17);
        // Position still in registry.
        assertEq(wallet.openPositionCount(), 1);
    }

    function test_decreasePosition_zeroDelta_reverts() public {
        bytes32 salt = bytes32(uint256(11));
        _open(salt, 1e18);

        vm.prank(owner);
        vm.expectRevert(V4PositionManager.ZeroDelta.selector);
        wallet.decreasePosition(salt, 0);
    }

    function test_decreasePosition_overflowDelta_reverts() public {
        bytes32 salt = bytes32(uint256(12));
        _open(salt, 1e18);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(V4PositionManager.DeltaExceedsLiquidity.selector, uint128(2e18), uint128(1e18))
        );
        wallet.decreasePosition(salt, 2e18);
    }

    function test_decreasePosition_unknownSalt_reverts() public {
        bytes32 salt = bytes32(uint256(13));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, salt));
        wallet.decreasePosition(salt, 1e15);
    }

    // ────────── pokePosition ──────────

    function test_pokePosition_collectsFeesOnly() public {
        bytes32 salt = bytes32(uint256(20));
        _open(salt, 1e18);
        uint128 liqBefore = wallet.positionOf(salt).liquidity;

        uint256 walletBal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(wallet));
        uint256 walletBal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(wallet));

        _swapThroughRange(true, -1e15);
        _swapThroughRange(false, -1e15);

        vm.prank(owner);
        wallet.pokePosition(salt);

        // Liquidity unchanged.
        assertEq(wallet.positionOf(salt).liquidity, liqBefore);
        // Got some fees on both sides.
        assertGt(MockERC20(Currency.unwrap(currency0)).balanceOf(address(wallet)), walletBal0Before);
        assertGt(MockERC20(Currency.unwrap(currency1)).balanceOf(address(wallet)), walletBal1Before);
    }

    function test_pokePosition_unknownSalt_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownPosition.selector, bytes32(uint256(21))));
        wallet.pokePosition(bytes32(uint256(21)));
    }

    // ────────── multi-position registry consistency ──────────

    function test_openMultiplePositions_independentSalts() public {
        bytes32 s1 = bytes32(uint256(101));
        bytes32 s2 = bytes32(uint256(102));
        bytes32 s3 = bytes32(uint256(103));

        _open(s1, 1e17);
        _open(s2, 2e17);
        _open(s3, 3e17);
        assertEq(wallet.openPositionCount(), 3);

        // Close out-of-order (middle first), then last, then first.
        vm.startPrank(owner);
        wallet.closePosition(s2);
        vm.stopPrank();
        assertEq(wallet.openPositionCount(), 2);
        // s2 gone, the remaining entries still resolve via positionOf.
        assertEq(wallet.positionOf(s2).liquidity, 0);
        assertEq(wallet.positionOf(s1).liquidity, 1e17);
        assertEq(wallet.positionOf(s3).liquidity, 3e17);

        // Confirm openSalts has exactly {s1, s3} in some order.
        bytes32 a = wallet.openSalts(0);
        bytes32 b = wallet.openSalts(1);
        assertTrue((a == s1 && b == s3) || (a == s3 && b == s1));

        vm.prank(owner);
        wallet.closePosition(s3);
        assertEq(wallet.openPositionCount(), 1);
        assertEq(wallet.openSalts(0), s1);

        vm.prank(owner);
        wallet.closePosition(s1);
        assertEq(wallet.openPositionCount(), 0);
    }
}
