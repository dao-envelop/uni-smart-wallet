// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {OpenVolatileLPManager} from "../src/OpenVolatileLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockERC20, MockPriceOracle, MockObserverHook} from "./helpers/Mocks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice `VolatileLPManager.moveLiquidity`: free a position in one pool and re-deploy it in another,
/// inside a single unlock. Two pools over the same pair at different fee tiers — the case the operation
/// exists for, and the one where "two transactions" is most obviously wasteful.
contract VolatileLPManagerMoveTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    VolatileLPManager internal mgr;
    MockPriceOracle internal oracle;

    Currency internal c0;
    Currency internal c1;

    PoolKey internal keyA; // fee 3000
    PoolKey internal keyB; // fee 500 — same pair, different pool
    PoolId internal poolA;
    PoolId internal poolB;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);
    address internal stranger = address(0xDEAD);
    address internal trader = address(0x77ADE);

    int24 internal constant SPACING = 60;
    uint256 internal constant FUND = 1_000e18;

    bytes32 internal constant SALT_A = bytes32(uint256(1));
    bytes32 internal constant SALT_B = bytes32(uint256(2));

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        oracle = new MockPriceOracle();

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);

        keyA = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(address(0))});
        keyB = PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolA = keyA.toId();
        poolB = keyB.toId();

        poolManager.initialize(keyA, TickMath.getSqrtPriceAtTick(0)); // 1:1
        poolManager.initialize(keyB, TickMath.getSqrtPriceAtTick(0));
        _seed(keyA);
        _seed(keyB);

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));

        PoolKey[] memory cfgs = new PoolKey[](2);
        cfgs[0] = keyA;
        cfgs[1] = keyB;
        mgr.initialize(
            VolatileLPManager.InitParams({
                owner: owner, name: bytes32("Vol"), descriptor: address(0), oracle: address(0), pools: cfgs
            })
        );

        MockERC20(Currency.unwrap(c0)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), FUND);

        vm.prank(owner);
        mgr.setOperator(bot, true);
        // Every operator op now needs the oracle, the swapless ones included (task_053): wire a vouching
        // one so the cases below test move mechanics rather than the guard. The guard has its own section.
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Pass);

        MockERC20(Currency.unwrap(c0)).mint(trader, 10_000e18);
        MockERC20(Currency.unwrap(c1)).mint(trader, 10_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Trade both ways through `k` so an in-range position there actually accrues fees. One
    /// direction would move the price out from under the position; the round trip leaves it in range.
    function _tradeThrough(PoolKey memory k) internal {
        for (uint256 i = 0; i < 2; ++i) {
            bool zeroForOne = i == 0;
            vm.prank(trader);
            swapRouter.swap(
                k,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -1e18,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
    }

    function _seed(PoolKey memory k) internal {
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

    function _leg(PoolId pid, bytes32 salt, int24 tl, int24 tu, uint256 amt)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg memory)
    {
        return VolatileLPManager.VolatileAllocLeg({
            poolId: pid,
            salt: salt,
            tickLower: tl,
            tickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    function _openInA(bytes32 salt, uint256 amt) internal returns (uint128) {
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(poolA, salt, -60, 60, amt);
        vm.prank(owner);
        mgr.allocate(legs);
        return mgr.positionOf(salt).liquidity;
    }

    function _saltIsOpen(bytes32 salt) internal view returns (bool) {
        for (uint256 i = 0; i < 8; ++i) {
            try mgr.openSalts(i) returns (bytes32 s) {
                if (s == salt) return true;
            } catch {
                return false;
            }
        }
        return false;
    }

    // ────────── the move itself ──────────

    function test_move_closesSourceAndOpensDestinationInAnotherPool() public {
        uint128 liq = _openInA(SALT_A, 100e18);

        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));

        assertEq(mgr.positionOf(SALT_A).liquidity, 0, "source closed");
        assertFalse(_saltIsOpen(SALT_A), "source salt spat out of openSalts");

        V4PositionManager.Position memory dst = mgr.positionOf(SALT_B);
        assertGt(dst.liquidity, 0, "destination funded");
        assertEq(PoolId.unwrap(dst.key.toId()), PoolId.unwrap(poolB), "destination is the other pool");
        assertTrue(_saltIsOpen(SALT_B), "destination salt registered");
    }

    function test_move_partial_leavesSourceOpen() public {
        uint128 liq = _openInA(SALT_A, 100e18);

        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq / 2, _leg(poolB, SALT_B, -60, 60, 40e18));

        assertEq(mgr.positionOf(SALT_A).liquidity, liq - liq / 2, "half of the source remains");
        assertTrue(_saltIsOpen(SALT_A), "source still open");
        assertGt(mgr.positionOf(SALT_B).liquidity, 0, "destination funded");
    }

    function test_move_intoExistingPosition_sumsLiquidity() public {
        uint128 liqA = _openInA(SALT_A, 100e18);

        // Open the destination first, then move into it: liquidity must add, not replace.
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(poolB, SALT_B, -60, 60, 50e18);
        vm.prank(owner);
        mgr.allocate(legs);
        uint128 before = mgr.positionOf(SALT_B).liquidity;

        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liqA, _leg(poolB, SALT_B, -60, 60, 90e18));

        assertGt(mgr.positionOf(SALT_B).liquidity, before, "top-up added to the existing position");
    }

    function test_move_intoExistingPositionWithAnotherRange_reverts() public {
        uint128 liqA = _openInA(SALT_A, 100e18);
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(poolB, SALT_B, -60, 60, 50e18);
        vm.prank(owner);
        mgr.allocate(legs);

        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(VolatileLPManager.RangeMismatch.selector, SALT_B));
        mgr.moveLiquidity(SALT_A, liqA, _leg(poolB, SALT_B, -120, 120, 90e18));
    }

    // ────────── refusals ──────────

    function test_move_zeroLiquidity_reverts() public {
        _openInA(SALT_A, 100e18);
        vm.prank(bot);
        vm.expectRevert(V4PositionManager.ZeroLiquidity.selector);
        mgr.moveLiquidity(SALT_A, 0, _leg(poolB, SALT_B, -60, 60, 90e18));
    }

    function test_move_addWithZeroLiquidity_reverts() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(bot);
        vm.expectRevert(V4PositionManager.ZeroLiquidity.selector);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 0));
    }

    function test_move_unconfiguredDestinationPool_reverts() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        PoolId ghost = PoolId.wrap(keccak256("not a configured pool"));
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnknownPool.selector, ghost));
        mgr.moveLiquidity(SALT_A, liq, _leg(ghost, SALT_B, -60, 60, 90e18));
    }

    function test_move_byStranger_reverts() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(stranger);
        vm.expectRevert(); // NotAuthorized — neither owner nor operator
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));
    }

    // ────────── the oracle guard, on the move's own swap ──────────

    function _legWithSwap(PoolId pid, bytes32 salt, uint256 amt)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg memory leg)
    {
        leg = _leg(pid, salt, -60, 60, amt);
        leg.zeroForOne = true;
        leg.swapAmountIn = 10e18;
        leg.swapPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
    }

    function test_move_operatorSwap_noOracle_reverts() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(owner);
        mgr.setPriceOracle(address(0)); // undo the setUp wiring: this case is about having no oracle
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.moveLiquidity(SALT_A, liq, _legWithSwap(poolB, SALT_B, 50e18));
    }

    function test_move_operatorSwap_oracleRejects_reverts() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Revert);

        vm.prank(bot);
        vm.expectRevert(MockPriceOracle.MockPriceOutOfBounds.selector);
        mgr.moveLiquidity(SALT_A, liq, _legWithSwap(poolB, SALT_B, 50e18));
    }

    function test_move_operatorSwap_oracleVouches_succeeds() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Pass);

        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _legWithSwap(poolB, SALT_B, 50e18));
        assertGt(mgr.positionOf(SALT_B).liquidity, 0, "moved with an oracle-vouched swap");
    }

    function test_move_ownerSwap_needsNoOracle() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(owner);
        mgr.moveLiquidity(SALT_A, liq, _legWithSwap(poolB, SALT_B, 50e18));
        assertGt(mgr.positionOf(SALT_B).liquidity, 0, "owner swaps freely");
    }

    // ────────── the structural guarantee ──────────

    function test_move_nothingLeavesTheManager() public {
        uint128 liq = _openInA(SALT_A, 100e18);

        uint256 ownerBefore0 = MockERC20(Currency.unwrap(c0)).balanceOf(owner);
        uint256 botBefore0 = MockERC20(Currency.unwrap(c0)).balanceOf(bot);
        uint256 strangerBefore1 = MockERC20(Currency.unwrap(c1)).balanceOf(stranger);

        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));

        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(owner), ownerBefore0, "owner gained nothing");
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(bot), botBefore0, "operator gained nothing");
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(stranger), strangerBefore1, "no third party paid");
    }

    function test_move_reportsTheFeesItRealised() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        _tradeThrough(keyA); // the position earns something worth reporting

        // The pull realises whatever the source accrued; the amounts must be announced, not swallowed
        // (finding 2026-08-22-recenter-erases-lifetime-fees).
        vm.recordLogs();
        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));

        (uint256 seen, uint256 f0, uint256 f1) = _feesReported(SALT_A);
        assertEq(seen, 1, "the pull announced its realised fees exactly once");
        assertTrue(f0 > 0 || f1 > 0, "and announced a non-zero amount");
    }

    /// @notice The other half of the same rule: a pull that realised nothing says nothing. Without the
    /// zero guard, `recenter`, `reinvest` and every allocate into a fresh salt would each emit an empty
    /// `FeesCollected` — a second, meaningless event per transaction that an indexer cannot tell from a
    /// real collection of zero.
    function test_move_withNothingAccrued_emitsNoFeeEvent() public {
        uint128 liq = _openInA(SALT_A, 100e18);

        vm.recordLogs();
        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));

        (uint256 seenA,,) = _feesReported(SALT_A);
        (uint256 seenB,,) = _feesReported(SALT_B);
        assertEq(seenA, 0, "nothing accrued on the source, nothing announced");
        assertEq(seenB, 0, "a fresh destination position has no fees to announce");
    }

    /// @dev How many `FeesCollected` this manager emitted for `salt` in the recorded logs, and the
    /// amounts of the last one.
    function _feesReported(bytes32 salt) internal returns (uint256 seen, uint256 fees0, uint256 fees1) {
        bytes32 topic = keccak256("FeesCollected(bytes32,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(mgr) && logs[i].topics[0] == topic && logs[i].topics[1] == salt) {
                ++seen;
                (fees0, fees1) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function test_move_emitsLiquidityMoved() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.expectEmit(true, true, false, true, address(mgr));
        emit VolatileLPManager.LiquidityMoved(SALT_A, SALT_B, liq);
        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));
    }

    // ────────── what it is for ──────────

    /// @notice The reason the operation exists: one transaction instead of withdrawTo + allocate, with
    /// no window in between where the capital is deployed nowhere.
    ///
    /// Measured, not asserted, and in two tests rather than one: whichever path runs second inherits the
    /// other's warm storage and accounts, which is worth more than the difference being measured. Each
    /// test therefore starts from the same fresh `setUp`. Same convention as `PoolCountScaling.t.sol`.
    function test_gas_moveLiquidity() public {
        uint128 liq = _openInA(SALT_A, 100e18);
        vm.prank(bot);
        uint256 g = gasleft();
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));
        emit log_named_uint("moveLiquidity, one unlock", g - gasleft());
    }

    function test_gas_withdrawThenAllocate() public {
        uint128 liq = _openInA(SALT_A, 100e18);

        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: SALT_A, liquidityToPull: liq});
        BaseLPManager.WithdrawSwap[] memory noSwaps = new BaseLPManager.WithdrawSwap[](0);
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _leg(poolB, SALT_B, -60, 60, 90e18);

        vm.startPrank(owner);
        uint256 g = gasleft();
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: address(mgr), requestedCurrency: c0, amount: 1, pulls: pulls, swaps: noSwaps
            })
        );
        mgr.allocate(legs);
        emit log_named_uint("withdrawTo + allocate, two unlocks", g - gasleft());
        vm.stopPrank();
        emit log_named_uint("plus one more intrinsic transaction cost", 21_000);
    }
}

/// @notice task_058: `moveLiquidity` with a bridge swap in a THIRD configured pool. The scenario the
/// overload exists for: the source (E/A) and the destination (U/T) share no currency, so the destination's
/// own pre-swap cannot fund it. Freed E is bridged to U through the E/U pool, then the destination leg
/// pre-swaps part of the U into T and adds. A stays idle on the manager — yield, not loss.
contract VolatileLPManagerMoveBridgeTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    MockPriceOracle internal oracle;
    VolatileLPManager internal volImpl;
    OpenVolatileLPManager internal openImpl;
    VolatileLPManager internal mgr;

    Currency internal E; // "ETH"
    Currency internal A; // "ARB"
    Currency internal U; // "USDC"
    Currency internal T; // "USDT"

    PoolKey internal keySrc; // E/A
    PoolKey internal keyBridge; // E/U
    PoolKey internal keyDst; // U/T

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant SALT_SRC = bytes32(uint256(1));
    bytes32 internal constant SALT_DST = bytes32(uint256(2));

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        oracle = new MockPriceOracle();
        oracle.setMode(MockPriceOracle.Mode.Pass);

        E = _mk();
        A = _mk();
        U = _mk();
        T = _mk();
        keySrc = _key(E, A, IHooks(address(0)));
        keyBridge = _key(E, U, IHooks(address(0)));
        keyDst = _key(U, T, IHooks(address(0)));
        _openAndSeed(keySrc);
        _openAndSeed(keyBridge);
        _openAndSeed(keyDst);

        volImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        openImpl = new OpenVolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = _manager(address(volImpl), keyBridge);
    }

    // ────────── helpers ──────────

    function _mk() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20()));
    }

    function _key(Currency a, Currency b, IHooks h) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: h});
    }

    function _openAndSeed(PoolKey memory k) internal {
        poolManager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        uint256 amt = 2_000_000e18;
        MockERC20(Currency.unwrap(k.currency0)).mint(lp, amt);
        MockERC20(Currency.unwrap(k.currency1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(k.currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(k.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    /// @dev A manager over [source, bridge, destination] with an operator and a vouching oracle, and a
    /// 100e18-each position opened in the source by the owner.
    function _manager(address implementation, PoolKey memory bridgeKey) internal returns (VolatileLPManager m) {
        m = VolatileLPManager(payable(Clones.clone(implementation)));
        PoolKey[] memory cfgs = new PoolKey[](3);
        cfgs[0] = keySrc;
        cfgs[1] = bridgeKey;
        cfgs[2] = keyDst;
        m.initialize(
            VolatileLPManager.InitParams({
                owner: owner, name: "", descriptor: address(0), oracle: address(oracle), pools: cfgs
            })
        );
        MockERC20(Currency.unwrap(E)).mint(address(m), 100e18);
        MockERC20(Currency.unwrap(A)).mint(address(m), 100e18);
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = _plainLeg(keySrc.toId(), SALT_SRC, 100e18, 100e18);
        vm.startPrank(owner);
        m.allocate(legs);
        m.setOperator(bot, true);
        vm.stopPrank();
    }

    function _plainLeg(PoolId pid, bytes32 salt, uint256 a0, uint256 a1)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg memory)
    {
        return VolatileLPManager.VolatileAllocLeg({
            poolId: pid,
            salt: salt,
            tickLower: -600,
            tickUpper: 600,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: a0,
            amount1Desired: a1,
            minLiquidity: 0
        });
    }

    /// @dev The destination leg: pre-swap 20e18 U → T inside U/T, then add ~19e18 of each.
    function _dstLeg() internal view returns (VolatileLPManager.VolatileAllocLeg memory leg) {
        leg = _plainLeg(keyDst.toId(), SALT_DST, 19e18, 19e18);
        bool uIsZero = Currency.unwrap(keyDst.currency0) == Currency.unwrap(U);
        leg.zeroForOne = uIsZero;
        leg.swapAmountIn = 20e18;
        leg.swapPriceLimit = uIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev Bridge: 45e18 E → U through E/U.
    function _bridge() internal view returns (VolatileLPManager.BridgeSwap memory b) {
        bool eIsZero = Currency.unwrap(keyBridge.currency0) == Currency.unwrap(E);
        b = VolatileLPManager.BridgeSwap({
            poolId: keyBridge.toId(),
            zeroForOne: eIsZero,
            amountIn: 45e18,
            priceLimit: eIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            minOut: 0
        });
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    // ────────── the move ──────────

    function test_bridge_operatorMovesAcrossPairsWithNoSharedCurrency() public {
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());

        assertEq(mgr.positionOf(SALT_SRC).liquidity, 0, "source closed");
        V4PositionManager.Position memory dst = mgr.positionOf(SALT_DST);
        assertGt(dst.liquidity, 0, "destination funded");
        assertEq(PoolId.unwrap(dst.key.toId()), PoolId.unwrap(keyDst.toId()), "in the U/T pool");
        assertGt(_bal(A, address(mgr)), 0, "the unbridged side stays idle on the manager");
    }

    /// @dev task_060: the chain above (E→U, then U→T) is allowed, but buying back a currency the op
    /// already sold is not, even through another pool: E→U in E/U, then A→E in E/A, is a cycle's last hop.
    function test_operatorCannotBuyBackASoldCurrency() public {
        MockERC20(Currency.unwrap(E)).mint(address(mgr), 10e18);
        MockERC20(Currency.unwrap(A)).mint(address(mgr), 10e18);
        VolatileLPManager.VolatileAllocLeg[] memory legs = new VolatileLPManager.VolatileAllocLeg[](2);
        legs[0] = _plainLeg(keyBridge.toId(), SALT_DST, 1e18, 1e18);
        legs[0].zeroForOne = Currency.unwrap(keyBridge.currency0) == Currency.unwrap(E); // E → U
        legs[0].swapAmountIn = 5e18;
        legs[0].swapPriceLimit = legs[0].zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        legs[1] = _plainLeg(keySrc.toId(), bytes32(uint256(3)), 1e18, 1e18);
        legs[1].zeroForOne = Currency.unwrap(keySrc.currency0) == Currency.unwrap(A); // A → E
        legs[1].swapAmountIn = 5e18;
        legs[1].swapPriceLimit = legs[1].zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapRoundTrip.selector, E));
        mgr.allocate(legs);
        vm.prank(owner);
        mgr.allocate(legs); // the owner is not bound
    }

    /// @dev Without the bridge the same destination is unreachable: the freed E/A cannot pay for U/T.
    function test_noBridge_sameDestinationFails() public {
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(); // the U the destination pre-swap needs was never freed ⇒ unlock cannot settle
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg());
    }

    function test_bridge_ownerNeedsNoOracle() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(0));
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(owner);
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());
        assertGt(mgr.positionOf(SALT_DST).liquidity, 0);
    }

    function test_bridge_emitsSameLiquidityMoved() public {
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.expectEmit(true, true, false, true, address(mgr));
        emit VolatileLPManager.LiquidityMoved(SALT_SRC, SALT_DST, liq);
        vm.prank(bot);
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());
    }

    // ────────── the oracle judges the bridge swap ──────────

    function test_bridge_operatorWithoutOracle_reverts() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(0));
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());
    }

    /// @dev `NotEnforced` declines every call; the first one reached is the bridge swap, so the revert
    /// names the BRIDGE pool — proof that it is the bridge pool's key the oracle was asked about.
    function test_bridge_oracleCannotVouch_namesTheBridgePool() public {
        oracle.setMode(MockPriceOracle.Mode.NotEnforced);
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.OperatorSwapUnverified.selector, keyBridge.toId()));
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());
    }

    function test_bridge_oracleRejectsDeviation_reverts() public {
        oracle.setMode(MockPriceOracle.Mode.Revert);
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(MockPriceOracle.MockPriceOutOfBounds.selector);
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());
    }

    // ────────── swap guards ──────────

    function test_bridge_minOutNotMet_reverts() public {
        VolatileLPManager.BridgeSwap memory b = _bridge();
        b.minOut = 45e18; // 1:1 pool with a 0.3% fee cannot deliver the full input back
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(VolatileLPManager.SwapMinOut.selector, keyBridge.toId()));
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), b);
    }

    function test_bridge_partialFill_reverts() public {
        VolatileLPManager.BridgeSwap memory b = _bridge();
        uint160 p = TickMath.getSqrtPriceAtTick(0);
        b.priceLimit = b.zeroForOne ? p - 1 : p + 1; // stops almost at once ⇒ partial fill
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.SwapSlippage.selector, keyBridge.toId()));
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), b);
    }

    function test_bridge_unknownPool_reverts() public {
        VolatileLPManager.BridgeSwap memory b = _bridge();
        PoolId ghost = PoolId.wrap(keccak256("not configured"));
        b.poolId = ghost;
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnknownPool.selector, ghost));
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), b);
    }

    /// @dev `amountIn == 0` is "no bridge": the pool id is not even looked up, and the call is exactly the
    /// three-argument form — here a same-pair move inside the source pool's currencies.
    function test_bridge_zeroAmount_isTheOldForm() public {
        VolatileLPManager.BridgeSwap memory none;
        none.poolId = PoolId.wrap(keccak256("ignored when amountIn == 0"));
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        VolatileLPManager.VolatileAllocLeg memory back = _plainLeg(keySrc.toId(), SALT_DST, 90e18, 90e18);
        vm.prank(bot);
        mgr.moveLiquidity(SALT_SRC, liq, back, none);
        assertGt(mgr.positionOf(SALT_DST).liquidity, 0);
    }

    function test_bridge_stranger_reverts() public {
        uint128 liq = mgr.positionOf(SALT_SRC).liquidity;
        vm.prank(stranger);
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        mgr.moveLiquidity(SALT_SRC, liq, _dstLeg(), _bridge());
    }

    function test_bothOverloads_haveDistinctSelectors() public pure {
        bytes4 old3 = bytes4(
            keccak256(
                "moveLiquidity(bytes32,uint128,(bytes32,bytes32,int24,int24,bool,uint256,uint160,uint256,uint256,uint256,uint128))"
            )
        );
        bytes4 new4 = bytes4(
            keccak256(
                "moveLiquidity(bytes32,uint128,(bytes32,bytes32,int24,int24,bool,uint256,uint160,uint256,uint256,uint256,uint128),(bytes32,bool,uint256,uint160,uint256))"
            )
        );
        assertEq(old3, bytes4(0xf959740c), "the three-argument selector callers already encode is unchanged");
        assertEq(new4, bytes4(0x6b154b41), "the bridge overload");
    }

    // ────────── Open: a hooked bridge pool is a configured pool like any other ──────────

    function test_open_bridgeThroughHookedPool() public {
        MockObserverHook proto = new MockObserverHook();
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        address hookAddr = address(uint160(0x4444 << 144) | flags);
        vm.etch(hookAddr, address(proto).code);
        PoolKey memory hookedBridge = _key(E, U, IHooks(hookAddr));
        _openAndSeed(hookedBridge);

        VolatileLPManager open = _manager(address(openImpl), hookedBridge);
        VolatileLPManager.BridgeSwap memory b = _bridge();
        b.poolId = hookedBridge.toId();
        uint128 liq = open.positionOf(SALT_SRC).liquidity;
        vm.prank(bot);
        open.moveLiquidity(SALT_SRC, liq, _dstLeg(), b);
        assertGt(open.positionOf(SALT_DST).liquidity, 0, "moved through the hooked bridge");
        assertGt(MockObserverHook(hookAddr).beforeAddCalls(), 0, "the hooked pool is live (seeded through it)");
    }
}
