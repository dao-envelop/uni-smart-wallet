// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {V4PositionManagerHarness} from "./helpers/V4PositionManagerHarness.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Tests the V4 mechanics layer ({V4PositionManager}) directly, via an ungated
/// harness, decoupled from the NFT/operator auth that lives in the product contracts.
contract V4PositionManagerTest is Test {
    using StateLibrary for IPoolManager;

    V4PositionManagerHarness internal mgr;
    PoolManager internal poolManager;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;

    PoolModifyLiquidityTest internal lpRouter;
    address internal lp = address(0xABCD);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;

    function setUp() public {
        poolManager = new PoolManager(address(this));

        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        (Currency a, Currency b) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        currency0 = a;
        currency1 = b;

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        mgr = new V4PositionManagerHarness(IPoolManager(address(poolManager)));

        // Fund the manager so it can settle adds/swaps from its own balance.
        MockERC20(Currency.unwrap(currency0)).mint(address(mgr), 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(mgr), 1_000e18);

        // Seed the pool with external liquidity so swaps have a counterparty.
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(currency0)).mint(lp, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(lp, 1_000e18);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(100e18), salt: 0}),
            ""
        );
        vm.stopPrank();
    }

    // ────────── position lifecycle ──────────

    function test_open_close_roundtrip_emptiesRegistry_andNets() public {
        bytes32 salt = bytes32(uint256(1));
        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(mgr));
        uint256 bal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(mgr));

        mgr.open(key, -SPACING, SPACING, 1e18, salt, 0, type(uint128).max, type(uint128).max);
        assertEq(mgr.openPositionCount(), 1, "registry has the open position");
        assertEq(mgr.positionOf(salt).liquidity, 1e18, "liquidity recorded");

        mgr.close(salt);
        assertEq(mgr.openPositionCount(), 0, "registry emptied on close");
        assertEq(mgr.positionOf(salt).liquidity, 0, "position cleared");

        // No external swaps occurred ⇒ principal returns minus at most rounding dust.
        assertApproxEqAbs(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(mgr)), bal0Before, 2, "currency0 nets back"
        );
        assertApproxEqAbs(
            MockERC20(Currency.unwrap(currency1)).balanceOf(address(mgr)), bal1Before, 2, "currency1 nets back"
        );
    }

    function test_open_exceedsAmount0Max_reverts() public {
        // Range straddles the current tick ⇒ both currencies are owed, so a zero amount0Max
        // cap trips. Assert the selector only — the owed amount in the args isn't known here.
        try mgr.open(key, -SPACING, SPACING, 1e18, bytes32(uint256(7)), 0, 0, type(uint128).max) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes4(err), V4PositionManager.ExceedsAmount0Max.selector, "reverts with ExceedsAmount0Max");
        }
    }

    // ────────── extensible dispatcher ──────────

    function test_unlockCallback_fromNonPoolManager_reverts() public {
        vm.expectRevert(V4PositionManager.NotPoolManager.selector);
        mgr.unlockCallback(abi.encode(uint8(0), bytes("")));
    }

    function test_dispatcher_unknownOp_reverts() public {
        // Reach the dispatcher legitimately (as the PoolManager) with an unhandled op code.
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.UnknownOp.selector, uint8(7)));
        mgr.unlockCallback(abi.encode(uint8(7), bytes("")));
    }

    // ────────── swap + add netting (the allocate pattern) ──────────

    function test_swapThenAdd_netsInOneUnlock() public {
        uint128 liqBefore = IPoolManager(address(poolManager)).getLiquidity(key.toId());

        // exactIn swap of token0 → token1, then add liquidity straddling the tick, all netted.
        mgr.swapThenAdd(
            V4PositionManagerHarness.SwapThenAddParams({
                key: key,
                zeroForOne: true,
                swapAmount: -1e15,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                tickLower: -SPACING,
                tickUpper: SPACING,
                liquidity: 1e15,
                salt: bytes32(uint256(99))
            })
        );

        // If settlement had been incomplete the unlock would have reverted (CurrencyNotSettled).
        uint128 liqAfter = IPoolManager(address(poolManager)).getLiquidity(key.toId());
        assertGt(liqAfter, liqBefore, "liquidity added in-range after the swap moved price within range");
    }

    // ────────── O(1) salt splice ──────────

    function test_removeSalt_o1_splice_outOfOrder() public {
        bytes32 s1 = bytes32(uint256(1));
        bytes32 s2 = bytes32(uint256(2));
        bytes32 s3 = bytes32(uint256(3));
        mgr.open(key, -SPACING, SPACING, 1e18, s1, 0, type(uint128).max, type(uint128).max);
        mgr.open(key, -SPACING, SPACING, 2e18, s2, 0, type(uint128).max, type(uint128).max);
        mgr.open(key, -SPACING, SPACING, 3e18, s3, 0, type(uint128).max, type(uint128).max);
        assertEq(mgr.openPositionCount(), 3);

        // Close the middle one: last salt (s3) should be swapped into its slot.
        mgr.close(s2);
        assertEq(mgr.openPositionCount(), 2, "count decremented");
        assertEq(mgr.positionOf(s2).liquidity, 0, "middle position cleared");
        assertEq(mgr.positionOf(s1).liquidity, 1e18, "s1 still intact");
        assertEq(mgr.positionOf(s3).liquidity, 3e18, "s3 still intact after splice");

        // Both survivors remain closable (their salt indexes stayed consistent).
        mgr.close(s1);
        mgr.close(s3);
        assertEq(mgr.openPositionCount(), 0, "all closed");
    }
}
