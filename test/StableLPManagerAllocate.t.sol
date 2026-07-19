// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockPriceOracle} from "./helpers/Mocks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract StableLPManagerAllocateTest is StableLPTestBase {
    function test_allocate_splitsAcrossThreePools_deltasNetToZero() public {
        uint256 quoteBefore = _bal(USDT, address(mgr));

        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));

        // A position opened in each of the 3 pools (no CurrencyNotSettled ⇒ deltas netted).
        assertEq(mgr.openPositionCount(), 3, "three positions");
        for (uint8 i = 0; i < 3; ++i) {
            assertGt(mgr.positionOf(_saltFor(i)).liquidity, 0, "pool funded");
        }
        // Most of the deposited USDT was consumed (dust may return).
        uint256 spent = quoteBefore - _bal(USDT, address(mgr));
        assertGt(spent, (FUND * 9) / 10, "at least 90pct of quote deployed");
        assertLe(spent, FUND, "never spends more than deposited");
    }

    function test_allocate_byOperator_succeeds() public {
        // Operator allocate with pre-swaps requires a vouching price oracle (audit M-VOL-2 fix); wire one.
        MockPriceOracle oracle = new MockPriceOracle();
        oracle.setMode(MockPriceOracle.Mode.Pass);
        vm.startPrank(owner);
        mgr.setOperator(bot, true);
        mgr.setPriceOracle(address(oracle));
        vm.stopPrank();

        vm.prank(bot);
        mgr.allocate(_allocateParams(FUND));
        assertEq(mgr.openPositionCount(), 3);
    }

    function test_allocate_byNonAuthorized_reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        mgr.allocate(_allocateParams(FUND));
    }

    function test_allocate_zeroLiquidity_reverts() public {
        // Zero desired amounts + minLiquidity 0 ⇒ L == 0. Rejected (audit L-REG-1: no ghost salt).
        BaseLPManager.AllocLeg[] memory legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: poolKeys[0].toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: 0,
            amount1Desired: 0,
            minLiquidity: 0
        });
        vm.prank(owner);
        vm.expectRevert(V4PositionManager.ZeroLiquidity.selector);
        mgr.allocate(legs);
        assertEq(mgr.openPositionCount(), 0, "no ghost position registered");
    }

    function test_allocate_noLegs_reverts() public {
        BaseLPManager.AllocLeg[] memory legs = new BaseLPManager.AllocLeg[](0);
        vm.prank(owner);
        vm.expectRevert(BaseLPManager.NoLegs.selector);
        mgr.allocate(legs);
    }

    function test_allocate_unknownPool_reverts() public {
        BaseLPManager.AllocLeg[] memory legs = _allocateParams(FUND);
        PoolId bogus = PoolId.wrap(bytes32(uint256(0xBAD))); // not a configured pool
        legs[0].poolId = bogus;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnknownPool.selector, bogus));
        mgr.allocate(legs);
    }

    function test_allocate_belowMinLiquidity_reverts() public {
        BaseLPManager.AllocLeg[] memory legs = _allocateParams(FUND);
        legs[0].minLiquidity = type(uint128).max; // impossible floor
        vm.prank(owner);
        vm.expectRevert();
        mgr.allocate(legs);
    }

    // ────────── hookless-only policy ──────────

    function test_initialize_hookedPool_reverts() public {
        address badHook = address(0xBADC0DE);
        StableLPManager.InitParams memory p = _initParams(owner);
        p.pools[1].key.hooks = IHooks(badHook); // a non-zero hook on one of the 3 pools
        // The factory bubbles the clone's own init revert.
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.HookNotAllowed.selector, badHook));
        FactoryHelper.cloneStable(factory, address(impl), p);
    }
}
