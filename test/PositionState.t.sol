// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";

/// @dev External boundary so library calls (inlined) are reachable from the test.
contract PositionStateWrapper {
    function value(IPoolManager pm, address owner, bytes32 salt, V4PositionManager.Position memory p)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return PositionState.value(pm, owner, salt, p);
    }
}

contract PositionStateTest is V4WalletTestBase {
    PoolSwapTest internal swapRouter;
    PositionStateWrapper internal lib;
    address internal trader = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        lib = new PositionStateWrapper();

        MockERC20(Currency.unwrap(currency0)).mint(trader, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 1_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _open(bytes32 salt) internal {
        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e18, salt, 0, type(uint128).max, type(uint128).max);
    }

    function _val(bytes32 salt) internal view returns (uint256 a0, uint256 a1, uint256 f0, uint256 f1) {
        return lib.value(IPoolManager(address(poolManager)), address(wallet), salt, wallet.positionOf(salt));
    }

    function _swap(bool zeroForOne, int256 amt) internal {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_principal_inRange_bothSidesNonZero_feesZeroBeforeSwaps() public {
        bytes32 salt = bytes32(uint256(1));
        _open(salt);
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = _val(salt);
        // Symmetric range around tick 0 ⇒ both currencies present in the principal.
        assertGt(a0, 0, "amount0");
        assertGt(a1, 0, "amount1");
        assertEq(f0, 0, "fees0 before swaps");
        assertEq(f1, 0, "fees1 before swaps");
    }

    function test_fees_accrueAfterSwaps() public {
        bytes32 salt = bytes32(uint256(2));
        _open(salt);
        _swap(true, -1e15);
        _swap(false, -1e15);
        (,, uint256 f0, uint256 f1) = _val(salt);
        assertGt(f0, 0, "fees0 accrued");
        assertGt(f1, 0, "fees1 accrued");
    }

    function test_unknownSalt_returnsZeroes() public view {
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = _val(bytes32(uint256(999)));
        assertEq(a0, 0);
        assertEq(a1, 0);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }
}
