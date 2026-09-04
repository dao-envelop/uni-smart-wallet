// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockERC20, MockPriceOracle} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice `VolatileLPManager.moveLiquidity`: free a position in one pool and re-deploy it in another,
/// inside a single unlock. Two pools over the same pair at different fee tiers — the case the operation
/// exists for, and the one where "two transactions" is most obviously wasteful.
contract VolatileLPManagerMoveTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
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

    int24 internal constant SPACING = 60;
    uint256 internal constant FUND = 1_000e18;

    bytes32 internal constant SALT_A = bytes32(uint256(1));
    bytes32 internal constant SALT_B = bytes32(uint256(2));

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
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
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
        );

        MockERC20(Currency.unwrap(c0)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), FUND);

        vm.prank(owner);
        mgr.setOperator(bot, true);
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

        // The pull realises whatever the source accrued; the amounts must be announced, not swallowed
        // (finding 2026-08-22-recenter-erases-lifetime-fees).
        vm.recordLogs();
        vm.prank(bot);
        mgr.moveLiquidity(SALT_A, liq, _leg(poolB, SALT_B, -60, 60, 90e18));

        bytes32 topic = keccak256("FeesCollected(bytes32,uint256,uint256)");
        uint256 seen;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(mgr) && logs[i].topics[0] == topic && logs[i].topics[1] == SALT_A) ++seen;
        }
        assertEq(seen, 1, "the pull announced its realised fees exactly once");
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
