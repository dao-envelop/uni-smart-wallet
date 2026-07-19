// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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

/// @notice Audit H-VOL-1 remediation: an operator-triggered swap (allocate pre-swap / recenter rebalance)
/// is allowed only when a price oracle vouches for it (fail-closed); the NFT owner keeps full freedom.
/// This is the fix for the drain where a compromised operator routes a position's principal through an
/// adverse, self-parameterized swap (see `audits/2026-07-18`).
contract VolatileLPManagerOperatorSwapGuardTest is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    VolatileLPManager internal mgr;
    MockPriceOracle internal oracle;

    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07); // compromised operator
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    uint256 internal constant FUND = 1_000e18;
    bytes32 internal constant SALT = bytes32(uint256(1));

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        oracle = new MockPriceOracle();

        Currency a = Currency.wrap(address(new MockERC20()));
        Currency b = Currency.wrap(address(new MockERC20()));
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolId = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        _seedPool();

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));
        PoolKey[] memory cfgs = new PoolKey[](1);
        cfgs[0] = key;
        mgr.initialize(
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
        );

        MockERC20(Currency.unwrap(c0)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), FUND);

        // Owner opens a position; then delegates operational rights to the (now hostile) bot.
        vm.startPrank(owner);
        mgr.allocate(_one(_leg(SALT, -60, 60, 100e18)));
        mgr.setOperator(bot, true);
        vm.stopPrank();
    }

    function _seedPool() internal {
        uint256 amt = 2_000_000e18;
        MockERC20(Currency.unwrap(c0)).mint(lp, amt);
        MockERC20(Currency.unwrap(c1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(c0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function _leg(bytes32 salt, int24 tl, int24 tu, uint256 amt)
        internal
        view
        returns (VolatileLPManager.VolatileAllocLeg memory l)
    {
        l = VolatileLPManager.VolatileAllocLeg({
            poolId: poolId,
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

    function _one(VolatileLPManager.VolatileAllocLeg memory l)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = l;
    }

    /// @dev A recenter that frees the whole position and dumps it through a wide-limit swap — the H-VOL-1
    /// drain shape. `minAmountOut`/`minLiquidity` are 0 and the price limit is maximally permissive.
    function _drainRecenter() internal pure returns (VolatileLPManager.RecenterParams memory) {
        return VolatileLPManager.RecenterParams({
            salt: SALT,
            newTickLower: -120,
            newTickUpper: 120,
            zeroForOne: true,
            swapAmountIn: 5e18,
            swapPriceLimit: TickMath.MIN_SQRT_PRICE + 1,
            minAmountOut: 0,
            minLiquidity: 0
        });
    }

    // ────────── operator: swap gated by the oracle (fail-closed) ──────────

    function test_operatorRecenterSwap_noOracle_reverts() public {
        vm.prank(bot);
        vm.expectRevert(VolatileLPManager.OperatorSwapGuardRequired.selector);
        mgr.recenter(_drainRecenter());
    }

    function test_operatorRecenterSwap_notEnforcedOracle_reverts() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle)); // default mode: NotEnforced (no fresh reference)
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(VolatileLPManager.OperatorSwapUnverified.selector, poolId));
        mgr.recenter(_drainRecenter());
    }

    function test_operatorRecenterSwap_outOfBoundsOracle_reverts() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Revert); // oracle rejects the adverse price
        vm.prank(bot);
        vm.expectRevert(MockPriceOracle.MockPriceOutOfBounds.selector);
        mgr.recenter(_drainRecenter());
    }

    function test_operatorRecenterSwap_inBoundsOracle_succeeds() public {
        vm.prank(owner);
        mgr.setPriceOracle(address(oracle));
        oracle.setMode(MockPriceOracle.Mode.Pass); // oracle vouches for the price
        vm.prank(bot);
        mgr.recenter(_drainRecenter());
        assertEq(mgr.positionOf(SALT).tickLower, int24(-120), "recenter applied under a vouching oracle");
    }

    function test_operatorAllocateSwap_noOracle_reverts() public {
        VolatileLPManager.VolatileAllocLeg memory l = _leg(bytes32(uint256(2)), -60, 60, 10e18);
        l.zeroForOne = true;
        l.swapAmountIn = 5e18;
        l.swapPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        vm.prank(bot);
        vm.expectRevert(VolatileLPManager.OperatorSwapGuardRequired.selector);
        mgr.allocate(_one(l));
    }

    // ────────── operator: swapless ops stay unrestricted ──────────

    function test_operatorSwaplessRecenter_noOracle_succeeds() public {
        VolatileLPManager.RecenterParams memory rp = _drainRecenter();
        rp.swapAmountIn = 0; // no swap ⇒ no value-loss vector ⇒ no guard
        vm.prank(bot);
        mgr.recenter(rp);
        assertEq(mgr.positionOf(SALT).tickLower, int24(-120), "swapless recenter allowed for operator");
    }

    function test_operatorSwaplessAllocate_noOracle_succeeds() public {
        vm.prank(bot);
        mgr.allocate(_one(_leg(bytes32(uint256(3)), -60, 60, 50e18)));
        assertGt(mgr.positionOf(bytes32(uint256(3))).liquidity, 0, "swapless allocate allowed for operator");
    }

    // ────────── owner: full freedom (bypasses the guard) ──────────

    function test_ownerRecenterSwap_noOracle_succeeds() public {
        vm.prank(owner);
        mgr.recenter(_drainRecenter()); // same drain-shape leg, but owner ⇒ no oracle required
        assertEq(mgr.positionOf(SALT).tickLower, int24(-120), "owner swap bypasses the operator guard");
    }
}
