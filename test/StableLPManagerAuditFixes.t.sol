// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Audit-remediation regression tests (#16): operator-list splice-on-disable and the
/// uninitialized-pool guard. (Fee round-up is covered by StableLPManagerProtocolFee's 90/10 split.)
contract StableLPManagerAuditFixesTest is StableLPTestBase {
    address internal newOwner = address(0xA11CE2);

    function test_operatorList_spliceOnDisable_keepsActiveSetCorrect() public {
        address opA = address(0xA1);
        address opB = address(0xB2);
        address opC = address(0xC3);

        vm.startPrank(owner);
        mgr.setOperator(opA, true);
        mgr.setOperator(opB, true);
        mgr.setOperator(opC, true);
        mgr.setOperator(opB, false); // spliced out of the active list
        vm.stopPrank();

        assertTrue(mgr.operators(opA));
        assertFalse(mgr.operators(opB));
        assertTrue(mgr.operators(opC));

        // Transfer clears the remaining ACTIVE operators (auto-clear invariant preserved).
        uint256 id = mgr.TOKEN_ID();
        vm.prank(owner);
        mgr.transferFrom(owner, newOwner, id);
        assertFalse(mgr.operators(opA));
        assertFalse(mgr.operators(opC));
        assertEq(mgr.ownerOf(mgr.TOKEN_ID()), newOwner);
    }

    function test_operatorList_reEnableChurn_doesNotBrickTransfer() public {
        // Old bug: each enable after a disable re-pushed the same address, growing the list
        // unboundedly until the per-transfer clear loop could OOG. With splice-on-disable the list
        // never exceeds the live operator count.
        vm.startPrank(owner);
        for (uint256 i = 0; i < 100; ++i) {
            mgr.setOperator(bot, true);
            mgr.setOperator(bot, false);
        }
        mgr.setOperator(bot, true); // leave one active
        vm.stopPrank();

        assertTrue(mgr.operators(bot));

        // Transfer still succeeds and clears the operator (list is compact, loop is bounded).
        uint256 id = mgr.TOKEN_ID();
        vm.prank(owner);
        mgr.transferFrom(owner, newOwner, id);
        assertFalse(mgr.operators(bot));
    }
}

/// @notice `_addLiquidity` must reject an allocate into a configured-but-uninitialized V4 pool
/// (parity with the base `_openPosition` guard).
contract StableLPUninitializedPoolTest is Test {
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    address internal owner = address(0xA11CE);

    function _tok() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20()));
    }

    function test_allocate_uninitializedPool_reverts() public {
        PoolManager pm = new PoolManager(address(this));
        StableLPManager impl = new StableLPManager(IPoolManager(address(pm)), address(0xFEE5));
        StableLPFactory factory = new StableLPFactory(address(impl));

        Currency a = _tok();
        Currency b = _tok();
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        // NOTE: we deliberately do NOT call pm.initialize(key, ...) — the pool stays uninitialized.

        StableLPManager.PoolConfig[] memory cfgs = new StableLPManager.PoolConfig[](1);
        cfgs[0] = StableLPManager.PoolConfig({key: key, tickLower: -60, tickUpper: 60});
        StableLPManager mgr = StableLPManager(
            payable(factory.createManager(
                    StableLPManager.InitParams({owner: owner, name: bytes32("Envelop StableLP"), pools: cfgs})
                ))
        );

        // Fund the manager so settlement isn't the first thing to fail.
        MockERC20(Currency.unwrap(c0)).mint(address(mgr), 100e18);
        MockERC20(Currency.unwrap(c1)).mint(address(mgr), 100e18);

        StableLPManager.AllocLeg[] memory legs = new StableLPManager.AllocLeg[](1);
        legs[0] = StableLPManager.AllocLeg({
            poolId: key.toId(),
            zeroForOne: false,
            swapAmountIn: 0, // no pre-swap, so we reach _addLiquidity directly
            swapPriceLimit: 0,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            minLiquidity: 0
        });

        vm.prank(owner);
        vm.expectRevert(V4PositionManager.PoolUninitialized.selector);
        mgr.allocate(legs);
    }
}
