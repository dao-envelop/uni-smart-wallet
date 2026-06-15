// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StableLPManager} from "../../src/StableLPManager.sol";
import {StableLPFactory} from "../../src/StableLPFactory.sol";
import {MockERC20} from "./Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Scaffolding for StableLPManager tests: a PoolManager, 4 stable tokens
/// (USDT quote + USDC/DAI/USDe pairs), 3 hookless pools initialized at 1:1 and seeded
/// with external liquidity, the implementation + factory, a manager cloned for `owner`
/// and funded with USDT.
abstract contract StableLPTestBase is Test {
    PoolManager internal poolManager;
    StableLPManager internal impl;
    StableLPFactory internal factory;
    StableLPManager internal mgr;
    PoolModifyLiquidityTest internal lpRouter;

    Currency internal USDT; // quote
    Currency internal USDC;
    Currency internal DAI;
    Currency internal USDe;
    Currency[3] internal pairOf; // pairOf[i] = non-quote side of pool i

    PoolKey[3] internal poolKeys;
    bytes32[3] internal baseSalts;

    address internal owner = address(0xA11CE);
    address internal bot = address(0xB07);
    address internal lp = address(0xABCD);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;
    uint256 internal constant FUND = 1_000e18;

    function setUp() public virtual {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        USDT = _mkToken();
        USDC = _mkToken();
        DAI = _mkToken();
        USDe = _mkToken();
        pairOf = [USDC, DAI, USDe];

        for (uint8 i = 0; i < 3; ++i) {
            baseSalts[i] = keccak256(abi.encode("envelop.stablelp.pool", i));
            poolKeys[i] = _sortedKey(USDT, pairOf[i]);
            poolManager.initialize(poolKeys[i], TickMath.getSqrtPriceAtTick(0));
            _seedPool(poolKeys[i]);
        }

        impl = new StableLPManager();
        factory = new StableLPFactory(address(impl));
        mgr = StableLPManager(payable(factory.createManager(_initParams(owner))));

        MockERC20(Currency.unwrap(USDT)).mint(address(mgr), FUND);
    }

    // ────────── helpers ──────────

    function _mkToken() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20()));
    }

    function _sortedKey(Currency a, Currency b) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
    }

    function _seedPool(PoolKey memory key) internal {
        // Deep full-range liquidity so the manager's allocate swaps barely move price and its
        // narrow [-60,60] positions stay in-range (stable pools are deep in practice).
        uint256 mintAmt = 2_000_000e18;
        MockERC20(Currency.unwrap(key.currency0)).mint(lp, mintAmt);
        MockERC20(Currency.unwrap(key.currency1)).mint(lp, mintAmt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function _initParams(address owner_) internal view returns (StableLPManager.InitParams memory p) {
        StableLPManager.PoolConfig[3] memory cfgs;
        for (uint8 i = 0; i < 3; ++i) {
            cfgs[i] = StableLPManager.PoolConfig({
                key: poolKeys[i],
                quoteSide: USDT,
                tickLower: TL,
                tickUpper: TU,
                weightBps: i == 0 ? 3334 : 3333,
                baseSalt: baseSalts[i]
            });
        }
        p = StableLPManager.InitParams({poolManager: address(poolManager), owner: owner_, pools: cfgs, quote: USDT});
    }

    function _saltFor(uint8 i) internal view returns (bytes32) {
        return keccak256(abi.encode(baseSalts[i], i));
    }

    /// @dev Build a 3-leg allocate that splits `total` USDT across the pools, swapping ~half
    /// of each leg's quote into the pair token for a balanced add.
    function _allocateParams(uint256 total) internal view returns (StableLPManager.AllocateParams memory p) {
        uint256 a = (total * 3334) / 10_000;
        uint256 b = (total * 3333) / 10_000;
        uint256 c = total - a - b;
        uint256[3] memory q = [a, b, c];
        StableLPManager.AllocLeg[] memory legs = new StableLPManager.AllocLeg[](3);
        for (uint8 i = 0; i < 3; ++i) {
            // quote→pair: zeroForOne iff USDT is currency0; pick the matching extreme price bound.
            bool quoteIsZero = Currency.unwrap(poolKeys[i].currency0) == Currency.unwrap(USDT);
            uint160 limit = quoteIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            legs[i] = StableLPManager.AllocLeg({
                poolIndex: i,
                quoteIn: q[i],
                swapQuoteToPair: q[i] / 2,
                swapPriceLimit: limit,
                minLiquidity: 0,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        }
        p = StableLPManager.AllocateParams({totalQuote: total, legs: legs});
    }

    /// @dev exactOut swap params to produce `amountOut` of `tokenOut` in pool `i`.
    function _exactOut(uint8 i, Currency tokenOut, uint256 amountOut)
        internal
        view
        returns (StableLPManager.WithdrawSwap memory)
    {
        PoolKey memory key = poolKeys[i];
        bool outIsZero = Currency.unwrap(tokenOut) == Currency.unwrap(key.currency0);
        bool zeroForOne = !outIsZero; // output token0 ⇒ oneForZero; output token1 ⇒ zeroForOne
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return StableLPManager.WithdrawSwap({
            poolIndex: i, zeroForOne: zeroForOne, amountSpecified: int256(amountOut), sqrtPriceLimitX96: limit
        });
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }
}
