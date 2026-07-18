// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice v2 behaviors on the 3-pool base: managed-stable union, multi-stable deposit, and the
/// manual-allocate guard (only the named stable may be drawn down).
contract StableLPManagerV2Test is StableLPTestBase {
    function test_managedStables_unionCountAndMembers() public view {
        // 3 pools USDT/{USDC,DAI,USDe} → union = {USDT,USDC,DAI,USDe}.
        assertEq(mgr.managedStablesCount(), 4, "union size");
        assertEq(mgr.poolCount(), 3, "pool count");
        assertTrue(mgr.isManagedStable(USDT) && mgr.isManagedStable(USDC));
        assertTrue(mgr.isManagedStable(DAI) && mgr.isManagedStable(USDe));
    }

    /// @dev One leg that deploys `source` into pool `i`: swap half of it into the pair, then LP both.
    function _legSwapAndLP(uint8 i, Currency source, uint256 amount)
        internal
        view
        returns (BaseLPManager.AllocLeg memory)
    {
        bool sourceIsZero = Currency.unwrap(poolKeys[i].currency0) == Currency.unwrap(source);
        uint160 limit = sourceIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 half = amount / 2;
        uint256 lpEach = (half * 95) / 100;
        return BaseLPManager.AllocLeg({
            poolId: poolKeys[i].toId(),
            zeroForOne: sourceIsZero,
            swapAmountIn: half,
            swapPriceLimit: limit,
            amount0Desired: lpEach,
            amount1Desired: lpEach,
            minLiquidity: 0
        });
    }

    function _legs(BaseLPManager.AllocLeg memory one) internal pure returns (BaseLPManager.AllocLeg[] memory a) {
        a = new BaseLPManager.AllocLeg[](1);
        a[0] = one;
    }

    function test_allocateFrom_manual_deploysNamedStable_onlyThatStableConsumed() public {
        uint256 amt = 100e18;
        MockERC20(Currency.unwrap(USDC)).mint(address(mgr), amt);

        uint256 usdcBefore = _bal(USDC, address(mgr));
        uint256 usdtBefore = _bal(USDT, address(mgr));

        vm.prank(owner);
        mgr.allocateFrom(USDC, amt, _legs(_legSwapAndLP(0, USDC, amt)));

        assertLt(_bal(USDC, address(mgr)), usdcBefore, "USDC drawn down");
        assertGe(_bal(USDT, address(mgr)), usdtBefore, "USDT must not be spent");
        assertGt(mgr.positionOf(_saltFor(0)).liquidity, 0, "pool0 position opened");
    }

    function test_allocateFrom_guard_revertsWhenOtherStableSpent() public {
        uint256 amt = 100e18;
        MockERC20(Currency.unwrap(USDC)).mint(address(mgr), amt);

        // A leg that LPs pool0 (USDC/USDT) with NO pre-swap, sourcing USDT directly from the
        // manager's pre-existing balance — which manual mode forbids (only USDC may be drawn down).
        BaseLPManager.AllocLeg memory leg = BaseLPManager.AllocLeg({
            poolId: poolKeys[0].toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: 10e18,
            amount1Desired: 10e18,
            minLiquidity: 0
        });

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnexpectedStableSpend.selector, USDT));
        mgr.allocateFrom(USDC, amt, _legs(leg));
    }

    function test_allocateFrom_notDeposited_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.NotDeposited.selector, USDC, uint256(0), uint256(1e18)));
        mgr.allocateFrom(USDC, 1e18, _legs(_legSwapAndLP(0, USDC, 1e18)));
    }

    function test_allocateFrom_unmanagedStable_reverts() public {
        Currency rogue = _mkToken();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnmanagedStable.selector, rogue));
        mgr.allocateFrom(rogue, 1e18, _legs(_legSwapAndLP(0, USDC, 1e18)));
    }
}

/// @notice Variable pool count: a manager configured with 7 arbitrary stable pools.
contract StableLPManyPoolsTest is Test {
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    address internal owner = address(0xA11CE);

    function _tok() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20()));
    }

    function _sorted(Currency a, Currency b) internal pure returns (Currency c0, Currency c1) {
        (c0, c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    function test_init_sevenPools_countsAndUnion() public {
        PoolManager pm = new PoolManager(address(this));
        StableLPManager impl = new StableLPManager(IPoolManager(address(pm)), address(0xFEE5));
        LPManagerFactory factory = FactoryHelper.single(address(this), address(impl));

        Currency hub = _tok();
        StableLPManager.StablePoolInit[] memory cfgs = new StableLPManager.StablePoolInit[](7);
        for (uint256 i = 0; i < 7; ++i) {
            (Currency c0, Currency c1) = _sorted(hub, _tok());
            cfgs[i] = StableLPManager.StablePoolInit({
                key: PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))}),
                tickLower: -60,
                tickUpper: 60
            });
        }

        StableLPManager mgr = FactoryHelper.cloneStable(
            factory,
            address(impl),
            StableLPManager.InitParams({
                owner: owner, name: bytes32("Envelop StableLP"), descriptor: address(0), pools: cfgs
            })
        );

        assertEq(mgr.poolCount(), 7, "seven pools configured");
        assertEq(mgr.managedStablesCount(), 8, "hub + 7 spokes");
        assertEq(mgr.ownerOf(mgr.TOKEN_ID()), owner, "singleton to owner");
    }
}
