// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {UniLens} from "../src/UniLens.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Diagnostic: how the manager's per-transaction cost scales with the number of configured
/// pools. Every O(n) path is measured on a freshly built manager with exactly n pools:
/// `createManager` (init loop), `allocate` over all n pools in one call, `withdrawTo` pulling all n
/// positions in one call, plus the two views the UI depends on (`tokenURI`, `UniLens.positions`).
/// No contract changes; the numbers are printed, not asserted, so the run is a measurement.
///
/// It runs up to the live `MAX_POOLS` (32 since task_052 — this table is what raised it). Rows beyond
/// that need the constant raised in `src/BaseLPManager.sol` for the duration of the run, and
/// `FOUNDRY_GAS_LIMIT` raised past foundry's 2^30 default, which the n = 96 row hits first.
contract PoolCountScalingTest is Test {
    address internal owner = address(0xA11CE);
    address internal lp = address(0xABCD);
    address internal treasury = address(0xFEE5);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;
    uint256 internal constant FUND_PER_POOL = 1_000e18;

    struct Ctx {
        PoolManager pm;
        PoolModifyLiquidityTest router;
        Currency quote;
        PoolKey[] keys;
        StableLPManager mgr;
        UniLens lens;
    }

    /// @notice Gas budget for the read paths at the cap. They are the ones with no upper bound in the
    /// contracts and no way for a caller to split the work: `tokenURI` is called by wallets and
    /// marketplaces, `managerConfig` / `oracleStatus` by every manager screen. 30 M is half an L1 block
    /// and well under geth's default `rpc.gascap` of 50 M.
    uint256 internal constant READ_BUDGET = 30_000_000;

    /// @notice The cap itself: a manager with exactly `MAX_POOLS` pools works end to end.
    function test_atMaxPools_everyWritePathWorks() public {
        uint256 n = 32;
        (Ctx memory c,) = _build(n);
        assertEq(uint256(c.mgr.MAX_POOLS()), n, "MAX_POOLS moved - re-measure before trusting this test");
        assertEq(c.mgr.poolCount(), n, "every pool configured");
        assertEq(c.mgr.managedStablesCount(), n + 1, "the shared quote plus one pair per pool");

        vm.prank(owner);
        c.mgr.allocate(_legs(c, n));
        assertEq(c.mgr.openPositionCount(), n, "a position in every pool");

        vm.prank(owner);
        c.mgr.claimFees(PoolId.unwrap(c.keys[0].toId()));

        // Build the params BEFORE pranking: `_withdrawAll` reads `positionOf`, and that external call
        // would consume the prank.
        BaseLPManager.WithdrawToParams memory wp = _withdrawAll(c, n);
        vm.prank(owner);
        c.mgr.withdrawTo(wp);
        assertEq(c.mgr.openPositionCount(), 0, "and all of them close in one call");
    }

    /// @notice What actually binds above the cap is the read side, so hold it to a number. `tokenURI`
    /// concatenates JSON per position and is quadratic; the lens aggregators fan out two staticcalls per
    /// managed currency and two per pool.
    function test_atMaxPools_readsStayWithinBudget() public {
        (Ctx memory c,) = _build(32);
        vm.prank(owner);
        c.mgr.allocate(_legs(c, 32));

        uint256 g = gasleft();
        c.mgr.tokenURI(1);
        uint256 gUri = g - gasleft();

        g = gasleft();
        c.lens.managerConfig(address(c.mgr), new address[](0));
        uint256 gCfg = g - gasleft();

        g = gasleft();
        c.lens.oracleStatus(address(c.mgr));
        uint256 gOracle = g - gasleft();

        g = gasleft();
        c.lens.positions(address(c.mgr));
        uint256 gPos = g - gasleft();

        console2.log("at 32 pools: tokenURI", gUri);
        console2.log("at 32 pools: managerConfig", gCfg);
        console2.log("at 32 pools: oracleStatus", gOracle);
        console2.log("at 32 pools: positions", gPos);

        assertLt(gUri, READ_BUDGET, "tokenURI over budget");
        assertLt(gCfg, READ_BUDGET, "managerConfig over budget");
        assertLt(gOracle, READ_BUDGET, "oracleStatus over budget");
        assertLt(gPos, READ_BUDGET, "positions over budget");
    }

    function test_gasByPoolCount() public {
        console2.log("n,init,allocate,withdraw,tokenURI,lensPositions");
        _row(1);
        _row(2);
        _row(4);
        _row(8);
        _row(16);
        _row(32);
    }

    /// @notice The tax every operation pays for a pool it does NOT touch: one leg allocated on a
    /// manager configured with n pools. `_settleManaged` walks the whole managed-currency union on
    /// every unlock, so this is the part an operator cannot split into smaller transactions.
    function test_gasOfOneLegByPoolCount() public {
        console2.log("n,allocate1leg,claimFees1,withdraw1");
        _row1(1);
        _row1(2);
        _row1(4);
        _row1(8);
        _row1(16);
        _row1(32);
    }

    function _row1(uint256 n) internal {
        (Ctx memory c,) = _build(n);
        BaseLPManager.AllocLeg[] memory all = _legs(c, n);
        BaseLPManager.AllocLeg[] memory one = new BaseLPManager.AllocLeg[](1);
        one[0] = all[0];

        vm.prank(owner);
        uint256 g = gasleft();
        c.mgr.allocate(one);
        uint256 gAlloc = g - gasleft();

        bytes32 salt = PoolId.unwrap(c.keys[0].toId());
        vm.prank(owner);
        g = gasleft();
        c.mgr.claimFees(salt);
        uint256 gClaim = g - gasleft();

        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: c.mgr.positionOf(salt).liquidity});
        BaseLPManager.WithdrawToParams memory wp = BaseLPManager.WithdrawToParams({
            recipient: owner,
            requestedCurrency: c.quote,
            amount: 1e18,
            pulls: pulls,
            swaps: new BaseLPManager.WithdrawSwap[](0)
        });
        vm.prank(owner);
        g = gasleft();
        c.mgr.withdrawTo(wp);
        uint256 gW = g - gasleft();

        console2.log(
            string.concat(vm.toString(n), ",", vm.toString(gAlloc), ",", vm.toString(gClaim), ",", vm.toString(gW))
        );
    }

    function _row(uint256 n) internal {
        (Ctx memory c, uint256 gInit) = _build(n);

        BaseLPManager.AllocLeg[] memory legs = _legs(c, n);
        vm.prank(owner);
        uint256 g = gasleft();
        c.mgr.allocate(legs);
        uint256 gAlloc = g - gasleft();

        BaseLPManager.WithdrawToParams memory wp = _withdrawAll(c, n);
        vm.prank(owner);
        g = gasleft();
        c.mgr.withdrawTo(wp);
        uint256 gWithdraw = g - gasleft();

        // Views: measured after allocate would be ideal, but withdrawTo just closed the positions,
        // so rebuild + allocate a second manager for the read numbers.
        (Ctx memory c2,) = _build(n);
        vm.prank(owner);
        c2.mgr.allocate(_legs(c2, n));
        g = gasleft();
        c2.mgr.tokenURI(1);
        uint256 gUri = g - gasleft();
        g = gasleft();
        c2.lens.positions(address(c2.mgr));
        uint256 gLens = g - gasleft();

        console2.log(
            string.concat(
                vm.toString(n),
                ",",
                vm.toString(gInit),
                ",",
                vm.toString(gAlloc),
                ",",
                vm.toString(gWithdraw),
                ",",
                vm.toString(gUri),
                ",",
                vm.toString(gLens)
            )
        );
    }

    function _build(uint256 n) internal returns (Ctx memory c, uint256 gInit) {
        c.pm = new PoolManager(address(this));
        c.router = new PoolModifyLiquidityTest(IPoolManager(address(c.pm)));
        c.lens = new UniLens();
        c.quote = _mkToken();
        c.keys = new PoolKey[](n);

        for (uint256 i = 0; i < n; ++i) {
            c.keys[i] = _sortedKey(c.quote, _mkToken());
            c.pm.initialize(c.keys[i], TickMath.getSqrtPriceAtTick(0));
            _seedPool(c, c.keys[i]);
        }

        StableLPManager impl = new StableLPManager(IPoolManager(address(c.pm)), treasury);
        LPManagerFactory f = FactoryHelper.single(address(this), address(impl));
        WalletPositionDescriptor descriptor = new WalletPositionDescriptor(new address[](0));

        StableLPManager.StablePoolInit[] memory cfgs = new StableLPManager.StablePoolInit[](n);
        for (uint256 i = 0; i < n; ++i) {
            cfgs[i] = StableLPManager.StablePoolInit({key: c.keys[i], tickLower: TL, tickUpper: TU});
        }
        StableLPManager.InitParams memory p = StableLPManager.InitParams({
            owner: owner, name: bytes32("Envelop StableLP"), descriptor: address(descriptor), pools: cfgs
        });

        uint256 g = gasleft();
        c.mgr = FactoryHelper.cloneStable(f, address(impl), p);
        gInit = g - gasleft();

        MockERC20(Currency.unwrap(c.quote)).mint(address(c.mgr), FUND_PER_POOL * n);
    }

    function _legs(Ctx memory c, uint256 n) internal view returns (BaseLPManager.AllocLeg[] memory legs) {
        legs = new BaseLPManager.AllocLeg[](n);
        for (uint256 i = 0; i < n; ++i) {
            bool quoteIsZero = Currency.unwrap(c.keys[i].currency0) == Currency.unwrap(c.quote);
            uint160 limit = quoteIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            uint256 half = FUND_PER_POOL / 2;
            uint256 lpEach = (half * 95) / 100;
            legs[i] = BaseLPManager.AllocLeg({
                poolId: c.keys[i].toId(),
                zeroForOne: quoteIsZero,
                swapAmountIn: half,
                swapPriceLimit: limit,
                amount0Desired: lpEach,
                amount1Desired: lpEach,
                minLiquidity: 0
            });
        }
    }

    /// @dev Pull every open position in one call and deliver a token-dust amount of the quote; the
    /// freed pair legs net back into the manager through `_settleManaged`, which is the loop over the
    /// managed-currency union (n + 1 currencies here).
    function _withdrawAll(Ctx memory c, uint256 n) internal view returns (BaseLPManager.WithdrawToParams memory wp) {
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](n);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 salt = PoolId.unwrap(c.keys[i].toId());
            pulls[i] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: c.mgr.positionOf(salt).liquidity});
        }
        wp = BaseLPManager.WithdrawToParams({
            recipient: owner,
            requestedCurrency: c.quote,
            amount: 1e18,
            pulls: pulls,
            swaps: new BaseLPManager.WithdrawSwap[](0)
        });
    }

    function _mkToken() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20()));
    }

    function _sortedKey(Currency a, Currency b) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
    }

    function _seedPool(Ctx memory c, PoolKey memory key) internal {
        uint256 mintAmt = 2_000_000e18;
        MockERC20(Currency.unwrap(key.currency0)).mint(lp, mintAmt);
        MockERC20(Currency.unwrap(key.currency1)).mint(lp, mintAmt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(c.router), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(c.router), type(uint256).max);
        c.router
            .modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
                }),
                ""
            );
        vm.stopPrank();
    }
}
