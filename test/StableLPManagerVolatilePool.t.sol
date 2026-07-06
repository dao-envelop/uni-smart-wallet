// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Diagnostic: StableLPManager on a VOLATILE pair (an ETH/USDT stand-in — two generic ERC20s
/// whose price is NOT pegged at 1:1). It documents, in code, WHY the manager is a stable-only product:
/// the per-pool tick range is fixed at `initialize` and cannot be recentered, so a volatile price
/// (a) makes `allocate` mint a one-sided position when the pool is off the configured band, and
/// (b) walks the position out of range, where it earns no fees and stays stuck with no on-chain fix.
///
/// These tests PASS: the degradation is the expected behavior, not a bug. They exist to justify that
/// arbitrary/volatile assets need a different product (per-call/updatable ranges + `amount*Max` +
/// active recentering — the `UniSmartWallet.openPosition` model), not `StableLPManager`.
contract StableLPManagerVolatilePoolTest is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal poolManager;
    StableLPManager internal impl;
    StableLPFactory internal factory;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);
    address internal trader = address(0xCAFE);

    // Stable-tuned config: narrow ±60 band around the *configured* price — exactly what the manager
    // uses for pegged pairs. On a volatile pair this band is the whole problem.
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        impl = new StableLPManager(IPoolManager(address(poolManager)), treasury);
        factory = new StableLPFactory(address(impl));
    }

    // ────────── scaffold ──────────

    /// @dev Spin up a fresh volatile pool initialized at `initTick`, seed it with external full-range
    /// liquidity, and clone a manager configured with the stable `[-60, 60]` band. Tokens are funded to
    /// the manager (both sides), to the seeding LP, and to the trader (for price-moving swaps).
    function _newPool(int24 initTick)
        internal
        returns (StableLPManager m, PoolKey memory key, bytes32 salt, Currency c0, Currency c1)
    {
        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(initTick));
        salt = PoolId.unwrap(key.toId());

        // Moderate full-range depth so a bounded swap can walk the price out of the ±60 band.
        _seed(key);

        StableLPManager.PoolConfig[] memory cfgs = new StableLPManager.PoolConfig[](1);
        cfgs[0] = StableLPManager.PoolConfig({key: key, tickLower: TL, tickUpper: TU});
        m = StableLPManager(
            payable(factory.createManager(
                    StableLPManager.InitParams({owner: owner, name: bytes32("Envelop VolatileLP"), pools: cfgs})
                ))
        );

        MockERC20(Currency.unwrap(c0)).mint(address(m), 1_000e18);
        MockERC20(Currency.unwrap(c1)).mint(address(m), 1_000e18);

        MockERC20(Currency.unwrap(c0)).mint(trader, 1e27);
        MockERC20(Currency.unwrap(c1)).mint(trader, 1e27);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _seed(PoolKey memory key) internal {
        uint256 amt = 100_000e18;
        MockERC20(Currency.unwrap(key.currency0)).mint(lp, amt);
        MockERC20(Currency.unwrap(key.currency1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(10_000e18), salt: 0}),
            ""
        );
        vm.stopPrank();
    }

    function _leg(PoolKey memory key, uint256 amt) internal pure returns (StableLPManager.AllocLeg[] memory legs) {
        legs = new StableLPManager.AllocLeg[](1);
        legs[0] = StableLPManager.AllocLeg({
            poolId: key.toId(),
            zeroForOne: false,
            swapAmountIn: 0, // no pre-swap: add straight from balances
            swapPriceLimit: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    /// @dev Push the pool price to `targetTick` via a bounded swap (partial-fill to the price limit),
    /// so the end price is deterministic regardless of pool depth. `zeroForOne` moves price down.
    function _pushPriceTo(PoolKey memory key, int24 targetTick) internal {
        (, int24 cur,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        bool zeroForOne = targetTick < cur; // token0->token1 lowers price
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(5e26), // huge exactIn; the price limit is the real stop
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    // ────────── tests ──────────

    /// @notice Off-peg pool: the fixed `[-60, 60]` band sits entirely below the market price (init tick
    /// 6000 ≈ +82% off 1:1), so `allocate` can only deposit ONE side. The manager opens a 100%-single-
    /// asset position — the same failure a 1:1-tuned band hits on a real ETH/USDT pool.
    function test_allocate_offPeg_mintsLopsidedPosition() public {
        (StableLPManager m, PoolKey memory key, bytes32 salt, Currency c0, Currency c1) = _newPool(6000);

        uint256 c0Before = _bal(c0, address(m));
        uint256 c1Before = _bal(c1, address(m));

        vm.prank(owner);
        m.allocate(_leg(key, 100e18));

        assertGt(m.positionOf(salt).liquidity, 0, "position opened");
        // Price is above the band ⇒ liquidity is sized from currency1 only: currency0 is untouched.
        assertEq(_bal(c0, address(m)), c0Before, "currency0 not spent (position is one-sided)");
        assertLt(_bal(c1, address(m)), c1Before, "only currency1 was deployed");
    }

    /// @notice Volatile move walks the position out of its fixed range: once the price leaves `[-60, 60]`
    /// the position earns ZERO fees on all subsequent volume, and there is no on-chain way to recenter —
    /// the stored ticks stay `[-60, 60]` even after a fresh `allocate`. The only fix is redeploying a clone.
    function test_positionExitsRange_afterVolatileSwap_earnsNoFees_cannotRecenter() public {
        (StableLPManager m, PoolKey memory key, bytes32 salt, Currency c0, Currency c1) = _newPool(0);

        vm.prank(owner);
        m.allocate(_leg(key, 100e18)); // in-range at tick 0: both sides deployed
        assertGt(m.positionOf(salt).liquidity, 0, "in-range position opened");

        // A large volatile swing pushes the price out of the band (tick 0 -> ~+300, above TU=60).
        _pushPriceTo(key, 300);
        (, int24 curTick,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        assertGt(curTick, TU, "price left the configured band");

        // Harvest the fees earned while the price was crossing the band, so we isolate out-of-range volume.
        vm.prank(owner);
        m.claimFees(salt);

        // Generate real trading volume that stays ABOVE the band (oscillate in [+120, +240]).
        _pushPriceTo(key, 120);
        _pushPriceTo(key, 240);
        _pushPriceTo(key, 120);

        // Out-of-range ⇒ the position collected nothing from that volume.
        uint256 c0Before = _bal(c0, address(m));
        uint256 c1Before = _bal(c1, address(m));
        vm.prank(owner);
        m.claimFees(salt);
        assertEq(_bal(c0, address(m)), c0Before, "no currency0 fees while out of range");
        assertEq(_bal(c1, address(m)), c1Before, "no currency1 fees while out of range");

        // No recenter: a fresh allocate reuses the SAME stored ticks — the position is stuck off-market.
        vm.prank(owner);
        m.allocate(_leg(key, 100e18));
        assertEq(m.positionOf(salt).tickLower, TL, "tickLower still stuck at -60");
        assertEq(m.positionOf(salt).tickUpper, TU, "tickUpper still stuck at +60");
    }
}
