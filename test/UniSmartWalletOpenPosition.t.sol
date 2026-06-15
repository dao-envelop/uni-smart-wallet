// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockERC20} from "./helpers/Mocks.sol";
import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";

contract UniSmartWalletOpenPositionTest is V4WalletTestBase {
    // ────────── happy path ──────────

    function test_openPosition_byNFTOwner_succeeds() public {
        bytes32 salt = bytes32(uint256(1));

        vm.prank(owner);
        wallet.openPosition(
            key,
            -SPACING,
            SPACING,
            1e15,
            salt,
            0, // no minPoolLiquidity floor
            type(uint128).max,
            type(uint128).max
        );

        assertEq(wallet.openPositionCount(), 1);
        V4PositionManager.Position memory p = wallet.positionOf(salt);
        assertEq(p.liquidity, 1e15);
        assertEq(p.tickLower, -SPACING);
        assertEq(p.tickUpper, SPACING);
        assertEq(p.openedAt, uint64(block.timestamp));
    }

    function test_openPosition_allowedHook_succeeds() public {
        // address(0) hook is seeded in the constructor — happy path
        // already covered above; this test re-asserts the property explicitly.
        assertTrue(wallet.allowedHooks(address(0)));
        bytes32 salt = bytes32(uint256(2));

        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e15, salt, 0, type(uint128).max, type(uint128).max);

        assertEq(wallet.positionOf(salt).liquidity, 1e15);
    }

    function test_openPosition_byOperator_succeeds() public {
        vm.prank(owner);
        wallet.setOperator(bot, true);

        bytes32 salt = bytes32(uint256(3));
        vm.prank(bot);
        wallet.openPosition(key, -SPACING, SPACING, 1e15, salt, 0, type(uint128).max, type(uint128).max);

        assertEq(wallet.positionOf(salt).liquidity, 1e15);
    }

    // ────────── auth ──────────

    function test_openPosition_byNonAuthorized_reverts() public {
        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotAuthorized.selector);
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(0), 0, type(uint128).max, type(uint128).max);
    }

    // ────────── salt collision ──────────

    function test_openPosition_saltCollision_reverts() public {
        bytes32 salt = bytes32(uint256(10));
        vm.startPrank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e15, salt, 0, type(uint128).max, type(uint128).max);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.SaltCollision.selector, salt));
        wallet.openPosition(key, -SPACING, SPACING, 1e15, salt, 0, type(uint128).max, type(uint128).max);
        vm.stopPrank();
    }

    function test_openPosition_zeroLiquidity_reverts() public {
        vm.prank(owner);
        vm.expectRevert(V4PositionManager.ZeroLiquidity.selector);
        wallet.openPosition(key, -SPACING, SPACING, 0, bytes32(uint256(11)), 0, type(uint128).max, type(uint128).max);
    }

    // ────────── hook policy ──────────

    function test_openPosition_disallowedHook_reverts() public {
        address badHook = address(0xBADC0DE);
        PoolKey memory badKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(badHook)
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.HookNotAllowed.selector, badHook));
        wallet.openPosition(
            badKey, -SPACING, SPACING, 1e15, bytes32(uint256(20)), 0, type(uint128).max, type(uint128).max
        );
    }

    // ────────── pool existence ──────────

    function test_openPosition_uninitializedPool_reverts() public {
        // Same currencies, different fee / spacing → fresh PoolId that wasn't initialized.
        PoolKey memory phantom = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(0))
        });

        vm.prank(owner);
        vm.expectRevert(V4PositionManager.PoolUninitialized.selector);
        wallet.openPosition(phantom, -200, 200, 1e15, bytes32(uint256(30)), 0, type(uint128).max, type(uint128).max);
    }

    function test_openPosition_belowMinLiquidity_reverts() public {
        // Pool is initialized but has zero liquidity in-range → getLiquidity returns 0.
        uint128 floor = 1_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.PoolLiquidityBelowMin.selector, uint128(0), floor));
        wallet.openPosition(
            key, -SPACING, SPACING, 1e15, bytes32(uint256(40)), floor, type(uint128).max, type(uint128).max
        );
    }

    // ────────── slippage ──────────

    function test_openPosition_exceedsAmount0Max_reverts() public {
        // amount0Max=1 wei → any non-zero owed0 fails. With tick=0 and a symmetric range,
        // both owed0 and owed1 are non-zero for liquidity > 0.
        vm.prank(owner);
        vm.expectRevert();
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(uint256(50)), 0, 1, type(uint128).max);
    }

    function test_openPosition_exceedsAmount1Max_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(uint256(51)), 0, type(uint128).max, 1);
    }

    // ────────── insufficient wallet balance ──────────

    function test_openPosition_insufficientBalance_reverts() public {
        uint256 balance = MockERC20(Currency.unwrap(currency0)).balanceOf(address(wallet));
        vm.prank(owner);
        wallet.executeEncodedTx(
            Currency.unwrap(currency0), 0, abi.encodeWithSignature("transfer(address,uint256)", alice, balance)
        );

        vm.prank(owner);
        vm.expectRevert();
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(uint256(60)), 0, type(uint128).max, type(uint128).max);
    }
}
