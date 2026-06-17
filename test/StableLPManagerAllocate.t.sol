// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

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
        vm.prank(owner);
        mgr.setOperator(bot, true);

        vm.prank(bot);
        mgr.allocate(_allocateParams(FUND));
        assertEq(mgr.openPositionCount(), 3);
    }

    function test_allocate_byNonAuthorized_reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SingletonNFTOwned.NotAuthorized.selector);
        mgr.allocate(_allocateParams(FUND));
    }

    function test_allocate_quoteSplitMismatch_reverts() public {
        StableLPManager.AllocateParams memory p = _allocateParams(FUND);
        p.legs[0].quoteIn += 1; // Σ quoteIn no longer == totalQuote
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StableLPManager.QuoteSplitMismatch.selector, FUND + 1, FUND));
        mgr.allocate(p);
    }

    function test_allocate_belowMinLiquidity_reverts() public {
        StableLPManager.AllocateParams memory p = _allocateParams(FUND);
        p.legs[0].minLiquidity = type(uint128).max; // impossible floor
        vm.prank(owner);
        vm.expectRevert();
        mgr.allocate(p);
    }

    // ────────── hookless-only policy ──────────

    function test_initialize_hookedPool_reverts() public {
        address badHook = address(0xBADC0DE);
        StableLPManager.InitParams memory p = _initParams(owner);
        p.pools[1].key.hooks = IHooks(badHook); // a non-zero hook on one of the 3 pools
        vm.expectRevert(abi.encodeWithSelector(V4PositionManager.HookNotAllowed.selector, badHook));
        factory.createManager(p);
    }
}
