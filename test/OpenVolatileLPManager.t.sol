// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {OpenVolatileLPManager} from "../src/OpenVolatileLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {MockERC20, MockObserverHook, MockBrickingHook} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice {OpenVolatileLPManager}: the Volatile product with the hook gate lifted.
///
/// The suite has two halves. The cheap half only needs a non-zero `hooks` field, because
/// `_registerPool` never touches the PoolManager — it records config. The expensive half runs real ops
/// against a pool whose hook is actually installed in v4, which requires the hook's code to sit at an
/// address whose low 14 bits advertise the callbacks it implements (`Hooks.sol:15-18`); see `_etchHook`.
///
/// It also covers a pre-existing gap: the hookless gate had a test for `StableLPManager` only
/// (`StableLPManagerAllocate.t.sol:94-103`) and none for `VolatileLPManager`.
contract OpenVolatileLPManagerTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    OpenVolatileLPManager internal impl;

    Currency internal c0;
    Currency internal c1;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    uint256 internal constant FUND = 1_000e18;

    /// @dev Any non-zero address is enough where only the config gate is under test.
    IHooks internal constant DUMMY_HOOK = IHooks(address(0xBADC0DE));

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        impl = new OpenVolatileLPManager(IPoolManager(address(poolManager)), treasury);
    }

    // ────────── helpers ──────────

    function _key(IHooks hooks) internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: hooks});
    }

    function _init(address managerImpl, PoolKey memory k) internal returns (address mgr) {
        mgr = Clones.clone(managerImpl);
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = k;
        VolatileLPManager(payable(mgr))
            .initialize(
                VolatileLPManager.InitParams({owner: owner, name: bytes32("Open"), descriptor: address(0), pools: cfgs})
            );
    }

    /// @dev Place `runtimeCode` at an address whose low bits carry `flags`, so v4 will accept it as a
    /// hook. v4 derives a hook's permissions from its address, not from its code, so a hook cannot be
    /// `new`-ed into place — every v4 test does this etch dance. The high bits are arbitrary padding
    /// chosen to keep the address clearly synthetic.
    function _etchHook(uint160 flags, bytes memory runtimeCode) internal returns (address hookAddr) {
        hookAddr = address(uint160(0x4444 << 144) | flags);
        vm.etch(hookAddr, runtimeCode);
    }

    function _observerHook() internal returns (MockObserverHook) {
        MockObserverHook proto = new MockObserverHook();
        // Only the two callbacks the mock implements — advertising more would make v4 call into a
        // function that reverts (`BaseTestHooks.HookNotImplemented`).
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        return MockObserverHook(_etchHook(flags, address(proto).code));
    }

    function _brickingHook() internal returns (MockBrickingHook) {
        MockBrickingHook proto = new MockBrickingHook();
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        return MockBrickingHook(_etchHook(flags, address(proto).code));
    }

    /// @dev Open the v4 pool at 1:1 and seed it with full-range liquidity from an unrelated LP.
    function _openAndSeed(PoolKey memory k) internal {
        poolManager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        uint256 amt = 2_000_000e18;
        MockERC20(Currency.unwrap(c0)).mint(lp, amt);
        MockERC20(Currency.unwrap(c1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function _fund(address mgr) internal {
        MockERC20(Currency.unwrap(c0)).mint(mgr, FUND);
        MockERC20(Currency.unwrap(c1)).mint(mgr, FUND);
    }

    function _leg(PoolId id, bytes32 salt, uint256 amt)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = VolatileLPManager.VolatileAllocLeg({
            poolId: id,
            salt: salt,
            tickLower: -60,
            tickUpper: 60,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    function _withdraw(bytes32 salt, uint128 liq, Currency requested, uint256 amount)
        internal
        pure
        returns (BaseLPManager.WithdrawToParams memory p)
    {
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: liq});
        p = BaseLPManager.WithdrawToParams({
            recipient: address(0xCAFE),
            requestedCurrency: requested,
            amount: amount,
            pulls: pulls,
            swaps: new BaseLPManager.WithdrawSwap[](0)
        });
    }

    // ────────── the gate is lifted here ──────────

    function test_initialize_hookedPool_accepted() public {
        address mgr = _init(address(impl), _key(DUMMY_HOOK));
        (PoolKey memory stored) = OpenVolatileLPManager(payable(mgr)).pools(0);
        assertEq(address(stored.hooks), address(DUMMY_HOOK), "hooked pool was configured");
    }

    function test_initialize_hooklessPool_stillAccepted() public {
        address mgr = _init(address(impl), _key(IHooks(address(0))));
        (PoolKey memory stored) = OpenVolatileLPManager(payable(mgr)).pools(0);
        assertEq(address(stored.hooks), address(0), "hookless pool still fine");
    }

    /// @dev Lifting the gate must not lift the other init guards.
    function test_initialize_duplicateHookedPool_stillReverts() public {
        address mgr = Clones.clone(address(impl));
        PoolKey[] memory cfgs = new PoolKey[](2);
        cfgs[0] = _key(DUMMY_HOOK);
        cfgs[1] = _key(DUMMY_HOOK);
        vm.expectPartialRevert(BaseLPManager.DuplicatePool.selector);
        VolatileLPManager(payable(mgr))
            .initialize(
                VolatileLPManager.InitParams({owner: owner, name: bytes32("Open"), descriptor: address(0), pools: cfgs})
            );
    }

    // ────────── ...and stays shut for the other two products ──────────

    /// @dev The coverage gap this task found: only StableLPManager had a hooked-pool test.
    function test_initialize_hookedPool_stillReverts_forVolatile() public {
        VolatileLPManager volImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        address mgr = Clones.clone(address(volImpl));
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = _key(DUMMY_HOOK);
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.HookNotAllowed.selector, address(DUMMY_HOOK)));
        VolatileLPManager(payable(mgr))
            .initialize(
                VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
            );
    }

    // ────────── product identity ──────────

    function test_identity() public view {
        assertEq(impl.ORACLE_TYPE(), 3002, "own oracle type");
        assertEq(impl.symbol(), "eOpenLP", "own symbol");
    }

    function test_oracleTypeEvent_atImplDeploy() public {
        vm.expectEmit(true, false, false, true);
        emit BaseLPManager.EnvelopV2OracleType(3002, "OpenVolatileLPManager");
        new OpenVolatileLPManager(IPoolManager(address(poolManager)), treasury);
    }

    function test_factoryClone_carriesOracleType() public {
        LPManagerFactory f = FactoryHelper.single(address(this), address(impl));
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = _key(DUMMY_HOOK);
        // The Volatile init selector is inherited verbatim, so the existing helper works unchanged.
        VolatileLPManager mgr = FactoryHelper.cloneVolatile(
            f,
            address(impl),
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Open"), descriptor: address(0), pools: cfgs})
        );
        assertEq(OpenVolatileLPManager(payable(address(mgr))).ORACLE_TYPE(), 3002, "clone reports 3002");
        assertEq(mgr.ownerOf(1), owner, "singleton NFT minted to owner");
    }

    // ────────── real ops against a really-hooked pool ──────────

    function test_allocateAndWithdraw_onHookedPool_invokesHook() public {
        MockObserverHook hook = _observerHook();
        PoolKey memory k = _key(IHooks(address(hook)));
        _openAndSeed(k);
        address mgr = _init(address(impl), k);
        _fund(mgr);

        uint256 addsAfterSeed = hook.beforeAddCalls();
        assertGt(addsAfterSeed, 0, "hook is really installed (the seed add went through it)");

        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(owner);
        OpenVolatileLPManager(payable(mgr)).allocate(_leg(k.toId(), salt, 100e18));
        uint128 liq = OpenVolatileLPManager(payable(mgr)).positionOf(salt).liquidity;
        assertGt(liq, 0, "liquidity minted on a hooked pool");
        assertEq(hook.beforeAddCalls(), addsAfterSeed + 1, "manager's add ran through the hook");

        OpenVolatileLPManager(payable(mgr)).withdrawTo(_withdraw(salt, liq, c0, 10e18));
        vm.stopPrank();

        assertEq(hook.beforeRemoveCalls(), 1, "manager's remove ran through the hook");
        assertEq(OpenVolatileLPManager(payable(mgr)).positionOf(salt).liquidity, 0, "position fully pulled");
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(address(0xCAFE)), 10e18, "recipient paid");
    }

    /// @dev The accepted risk, as a passing test rather than a comment: a hook that reverts on
    /// `beforeRemoveLiquidity` lets deposits in and then traps them — `withdrawTo` cannot complete.
    /// This is why hookless {VolatileLPManager} stays the default a UI offers first.
    function test_brickingHook_trapsPrincipal() public {
        MockBrickingHook hook = _brickingHook();
        PoolKey memory k = _key(IHooks(address(hook)));
        _openAndSeed(k);
        address mgr = _init(address(impl), k);
        _fund(mgr);

        bytes32 salt = bytes32(uint256(1));
        vm.startPrank(owner);
        OpenVolatileLPManager(payable(mgr)).allocate(_leg(k.toId(), salt, 100e18));
        uint128 liq = OpenVolatileLPManager(payable(mgr)).positionOf(salt).liquidity;
        assertGt(liq, 0, "deposit accepted");

        vm.expectRevert(); // the hook's own revert, wrapped by v4
        OpenVolatileLPManager(payable(mgr)).withdrawTo(_withdraw(salt, liq, c0, 1e18));
        vm.stopPrank();

        assertEq(OpenVolatileLPManager(payable(mgr)).positionOf(salt).liquidity, liq, "principal still stuck");
    }
}
