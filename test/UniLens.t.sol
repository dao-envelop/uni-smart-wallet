// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {UniLens} from "../src/UniLens.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice UniLens over a UniSmartWallet: each `PositionView` must equal the underlying `positionOf` +
/// `PositionState.value` (the library the lens wraps), including fees carried through after real swaps.
contract UniLensWalletTest is V4WalletTestBase {
    UniLens internal lens;
    PoolSwapTest internal swapRouter;
    address internal trader = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        lens = new UniLens();
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(currency0)).mint(trader, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 1_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _open(bytes32 salt, int24 tl, int24 tu) internal {
        vm.prank(owner);
        wallet.openPosition(key, tl, tu, 1e18, salt, 0, type(uint128).max, type(uint128).max);
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

    function test_positions_matchPositionStateAndCarryFees() public {
        bytes32 s1 = bytes32(uint256(1));
        bytes32 s2 = bytes32(uint256(2));
        _open(s1, -SPACING, SPACING);
        _open(s2, -2 * SPACING, 2 * SPACING);
        _swap(true, -1e15);
        _swap(false, -1e15);

        UniLens.PositionView[] memory views = lens.positions(address(wallet));
        assertEq(views.length, wallet.openPositionCount(), "count == openPositionCount");
        assertEq(views.length, 2, "two positions");

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), key.toId());
        for (uint256 i = 0; i < views.length; ++i) {
            UniLens.PositionView memory v = views[i];
            V4PositionManager.Position memory p = wallet.positionOf(v.salt);
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
                PositionState.value(IPoolManager(address(poolManager)), address(wallet), v.salt, p);
            assertEq(v.liquidity, p.liquidity, "liquidity");
            assertEq(v.tickLower, p.tickLower, "tickLower");
            assertEq(v.tickUpper, p.tickUpper, "tickUpper");
            assertEq(v.sqrtPriceX96, sqrtP, "sqrtPriceX96");
            assertEq(v.amount0, a0, "amount0");
            assertEq(v.amount1, a1, "amount1");
            assertEq(v.fees0, f0, "fees0");
            assertEq(v.fees1, f1, "fees1");
        }
        assertTrue(views[0].fees0 > 0 || views[0].fees1 > 0, "fees carried through");
    }

    function test_position_single() public {
        bytes32 s = bytes32(uint256(7));
        _open(s, -SPACING, SPACING);
        UniLens.PositionView memory v = lens.position(address(wallet), s);
        assertEq(v.salt, s, "salt");
        assertEq(v.liquidity, 1e18, "liquidity");
        assertGt(v.amount0, 0, "amount0");
        assertGt(v.amount1, 0, "amount1");
        assertGt(uint256(v.sqrtPriceX96), 0, "price");
    }
}

/// @notice UniLens over a StableLPManager: portfolio after allocate + the manager config view.
contract UniLensManagerTest is StableLPTestBase {
    UniLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = new UniLens();
    }

    function test_positions_afterAllocate() public {
        vm.prank(owner);
        mgr.allocate(_allocateParams(300e18));

        UniLens.PositionView[] memory views = lens.positions(address(mgr));
        assertEq(views.length, mgr.openPositionCount(), "count");
        assertEq(views.length, 3, "one position per pool");
        for (uint256 i = 0; i < views.length; ++i) {
            assertGt(views[i].liquidity, 0, "liquidity > 0");
            assertGt(uint256(views[i].sqrtPriceX96), 0, "price set");
        }
    }

    function test_managerInfo() public view {
        UniLens.ManagerView memory info = lens.managerInfo(address(mgr));
        assertEq(info.owner, owner, "owner");
        assertEq(info.treasury, treasury, "treasury");
        assertEq(uint256(info.protocolFeeBps), 1000, "protocol fee bps");
        assertEq(info.managedStables.length, 4, "USDT + 3 pair sides");
        assertEq(info.idleBalances.length, 4, "idle balances aligned");
        assertEq(info.pools.length, 3, "3 configured pools");

        // The manager was funded with FUND USDT and nothing allocated yet → its idle USDT == FUND.
        bool sawUsdt;
        for (uint256 i = 0; i < info.managedStables.length; ++i) {
            if (Currency.unwrap(info.managedStables[i]) == Currency.unwrap(USDT)) {
                assertEq(info.idleBalances[i], FUND, "USDT idle == FUND");
                sawUsdt = true;
            }
        }
        assertTrue(sawUsdt, "USDT is managed");
    }
}
