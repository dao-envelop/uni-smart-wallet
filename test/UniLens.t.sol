// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {UniLens} from "../src/UniLens.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice UniLens over an NFT-owned position manager: each `PositionView` must equal the underlying `positionOf` +
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

    function test_managerConfig() public {
        // Extra candidates: one funded, one empty, and a managed token (USDT) which must be excluded.
        MockERC20 funded = new MockERC20();
        MockERC20 empty = new MockERC20();
        funded.mint(address(mgr), 25e18);

        address[] memory extra = new address[](3);
        extra[0] = address(funded);
        extra[1] = address(empty);
        extra[2] = Currency.unwrap(USDT); // already managed → must be excluded

        UniLens.ManagerConfig memory cfg = lens.managerConfig(address(mgr), extra);

        assertEq(cfg.owner, owner, "owner");
        assertEq(cfg.treasury, treasury, "treasury");
        assertEq(uint256(cfg.protocolFeeBps), 1000, "protocol fee bps");
        assertEq(cfg.oracleType, 3000, "stable oracle type");
        assertEq(cfg.positionDescriptor, address(0), "no descriptor wired");
        assertEq(cfg.priceOracle, address(0), "no price oracle set");
        assertEq(cfg.name, "Envelop StableLP", "name");

        // managed: index-aligned to managedStables, with decimals/symbol/idle.
        assertEq(cfg.managed.length, 4, "USDT + 3 pair sides");
        for (uint256 i = 0; i < cfg.managed.length; ++i) {
            Currency c = mgr.managedStables(i);
            assertEq(Currency.unwrap(cfg.managed[i].currency), Currency.unwrap(c), "managed index-aligned");
            assertEq(cfg.managed[i].decimals, 18, "mock decimals");
            assertEq(cfg.managed[i].symbol, "MCK", "mock symbol");
            assertEq(cfg.managed[i].idle, c.balanceOf(address(mgr)), "idle == manager balance");
            if (Currency.unwrap(c) == Currency.unwrap(USDT)) {
                assertEq(cfg.managed[i].idle, FUND, "USDT idle == FUND");
            }
        }

        // extra: only the funded, not-already-managed token.
        assertEq(cfg.extra.length, 1, "only the funded extra");
        assertEq(Currency.unwrap(cfg.extra[0].currency), address(funded), "extra == funded token");
        assertEq(cfg.extra[0].idle, 25e18, "extra idle");
        assertEq(cfg.extra[0].decimals, 18, "extra decimals");
        assertEq(cfg.extra[0].symbol, "MCK", "extra symbol");

        // pools: live slot0 + total liquidity.
        assertEq(cfg.pools.length, 3, "3 configured pools");
        IPoolManager pm = IPoolManager(address(poolManager));
        for (uint256 i = 0; i < cfg.pools.length; ++i) {
            (uint160 sqrtP,,,) = StateLibrary.getSlot0(pm, cfg.pools[i].key.toId());
            uint128 liq = StateLibrary.getLiquidity(pm, cfg.pools[i].key.toId());
            assertEq(cfg.pools[i].sqrtPriceX96, sqrtP, "sqrtPriceX96 == getSlot0");
            assertEq(cfg.pools[i].liquidity, liq, "liquidity == getLiquidity");
            assertGt(uint256(cfg.pools[i].sqrtPriceX96), 0, "price set");
        }
    }

    function test_managerFull_equalsConfigAndPositions() public {
        vm.prank(owner);
        mgr.allocate(_allocateParams(300e18));

        address[] memory extra = new address[](0);
        UniLens.ManagerFull memory full = lens.managerFull(address(mgr), extra);
        UniLens.ManagerConfig memory cfg = lens.managerConfig(address(mgr), extra);
        UniLens.PositionView[] memory pv = lens.positions(address(mgr));

        // .config equals managerConfig (spot-check identity fields + array shapes).
        assertEq(full.config.owner, cfg.owner, "config.owner");
        assertEq(full.config.name, cfg.name, "config.name");
        assertEq(full.config.oracleType, cfg.oracleType, "config.oracleType");
        assertEq(full.config.managed.length, cfg.managed.length, "config.managed length");
        assertEq(full.config.pools.length, cfg.pools.length, "config.pools length");
        assertEq(full.config.pools[0].sqrtPriceX96, cfg.pools[0].sqrtPriceX96, "config.pools price");

        // .positions equals positions().
        assertEq(full.positions.length, pv.length, "positions length");
        assertEq(full.positions.length, 3, "one position per pool");
        for (uint256 i = 0; i < pv.length; ++i) {
            assertEq(full.positions[i].salt, pv[i].salt, "salt");
            assertEq(full.positions[i].liquidity, pv[i].liquidity, "liquidity");
            assertEq(full.positions[i].amount0, pv[i].amount0, "amount0");
            assertEq(full.positions[i].amount1, pv[i].amount1, "amount1");
            assertEq(full.positions[i].fees0, pv[i].fees0, "fees0");
            assertEq(full.positions[i].fees1, pv[i].fees1, "fees1");
        }
    }
}

/// @notice UniLens `managerConfig` over a manager with a native-ETH managed currency: the native side
/// reports decimals 18, symbol "ETH", and the manager's ETH balance as idle.
contract UniLensNativeTest is Test {
    PoolManager internal poolManager;
    StableLPManager internal mgr;
    UniLens internal lens;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    Currency internal token; // currency1

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE5);
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        token = Currency.wrap(address(new MockERC20()));

        PoolKey memory key =
            PoolKey({currency0: NATIVE, currency1: token, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        StableLPManager impl = new StableLPManager(IPoolManager(address(poolManager)), treasury);
        LPManagerFactory factory = FactoryHelper.single(address(this), address(impl));
        StableLPManager.StablePoolInit[] memory cfgs = new StableLPManager.StablePoolInit[](1);
        cfgs[0] = StableLPManager.StablePoolInit({key: key, tickLower: TL, tickUpper: TU});
        mgr = FactoryHelper.cloneStable(
            factory,
            address(impl),
            StableLPManager.InitParams({
                owner: owner, name: bytes32("Envelop StableLP"), descriptor: address(0), pools: cfgs
            })
        );

        vm.deal(address(mgr), 100 ether);
        MockERC20(Currency.unwrap(token)).mint(address(mgr), 1_000e18);

        lens = new UniLens();
    }

    function test_managerConfig_nativeManagedCurrency() public view {
        address[] memory extra = new address[](0);
        UniLens.ManagerConfig memory cfg = lens.managerConfig(address(mgr), extra);

        bool sawNative;
        for (uint256 i = 0; i < cfg.managed.length; ++i) {
            if (Currency.unwrap(cfg.managed[i].currency) == address(0)) {
                assertEq(cfg.managed[i].decimals, 18, "native decimals 18");
                assertEq(cfg.managed[i].symbol, "ETH", "native symbol ETH");
                assertEq(cfg.managed[i].idle, address(mgr).balance, "native idle == manager ETH balance");
                assertEq(cfg.managed[i].idle, 100 ether, "funded with 100 ETH");
                sawNative = true;
            }
        }
        assertTrue(sawNative, "native currency surfaced in managed");
    }
}
