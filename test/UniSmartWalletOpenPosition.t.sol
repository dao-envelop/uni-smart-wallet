// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {PositionMath} from "../src/lib/PositionMath.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {MockERC20} from "./helpers/Mocks.sol";

contract UniSmartWalletOpenPositionTest is Test {
    using StateLibrary for IPoolManager;

    UniSmartWallet internal wallet;
    PoolManager internal poolManager;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Currency internal currency0;
    Currency internal currency1;

    PoolKey internal key;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal bot = address(0xB07);

    int24 internal constant SPACING = 60;
    uint160 internal sqrtPriceAtTick0;

    function setUp() public {
        poolManager = new PoolManager(address(this));

        tokenA = new MockERC20();
        tokenB = new MockERC20();
        (Currency a, Currency b) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        currency0 = a;
        currency1 = b;

        sqrtPriceAtTick0 = TickMath.getSqrtPriceAtTick(0);

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        poolManager.initialize(key, sqrtPriceAtTick0);

        vm.prank(owner);
        wallet = new UniSmartWallet(IPoolManager(address(poolManager)));

        // Fund the wallet generously so settle never accidentally fails for non-balance reasons.
        MockERC20(Currency.unwrap(currency0)).mint(address(wallet), 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(wallet), 1_000e18);
    }

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
        UniSmartWallet.Position memory p = wallet.positionOf(salt);
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
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.SaltCollision.selector, salt));
        wallet.openPosition(key, -SPACING, SPACING, 1e15, salt, 0, type(uint128).max, type(uint128).max);
        vm.stopPrank();
    }

    function test_openPosition_zeroLiquidity_reverts() public {
        vm.prank(owner);
        vm.expectRevert(UniSmartWallet.ZeroLiquidity.selector);
        wallet.openPosition(key, -SPACING, SPACING, 0, bytes32(uint256(11)), 0, type(uint128).max, type(uint128).max);
    }

    // ────────── hook policy ──────────

    function test_openPosition_disallowedHook_reverts() public {
        address badHook = address(0xBADC0DE);
        PoolKey memory badKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(badHook)
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.HookNotAllowed.selector, badHook));
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
        vm.expectRevert(UniSmartWallet.PoolUninitialized.selector);
        wallet.openPosition(phantom, -200, 200, 1e15, bytes32(uint256(30)), 0, type(uint128).max, type(uint128).max);
    }

    function test_openPosition_belowMinLiquidity_reverts() public {
        // Pool is initialized but has zero liquidity in-range → getLiquidity returns 0.
        uint128 floor = 1_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.PoolLiquidityBelowMin.selector, uint128(0), floor));
        wallet.openPosition(
            key, -SPACING, SPACING, 1e15, bytes32(uint256(40)), floor, type(uint128).max, type(uint128).max
        );
    }

    // ────────── slippage ──────────

    function test_openPosition_exceedsAmount0Max_reverts() public {
        // amount0Max=1 wei → any non-zero owed0 fails. With tick=0 and a symmetric range,
        // both owed0 and owed1 are non-zero for liquidity > 0.
        vm.prank(owner);
        vm.expectRevert(); // ExceedsAmount0Max with specific values; the values are deterministic but verbose
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(uint256(50)), 0, 1, type(uint128).max);
    }

    function test_openPosition_exceedsAmount1Max_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(uint256(51)), 0, type(uint128).max, 1);
    }

    // ────────── insufficient wallet balance ──────────

    function test_openPosition_insufficientBalance_reverts() public {
        // Drain wallet of currency0 so settle for currency0 fails (ERC20 transfer revert).
        uint256 balance = MockERC20(Currency.unwrap(currency0)).balanceOf(address(wallet));
        vm.prank(owner);
        wallet.executeEncodedTx(
            Currency.unwrap(currency0), 0, abi.encodeWithSignature("transfer(address,uint256)", alice, balance)
        );

        vm.prank(owner);
        vm.expectRevert(); // ERC20InsufficientBalance / similar from inside settle's transfer
        wallet.openPosition(key, -SPACING, SPACING, 1e15, bytes32(uint256(60)), 0, type(uint128).max, type(uint128).max);
    }
}
