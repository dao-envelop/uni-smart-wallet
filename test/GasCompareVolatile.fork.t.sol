// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Planner, Plan} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev Minimal Chainlink surface for reading the reference price in `setUp`.
interface IAggV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Base-fork gas benchmark for `VolatileLPManager`: measures gas on every op (allocate,
/// claimFees, recenter, withdrawTo, createManager) against the LIVE Base v4 PoolManager, and compares
/// `recenter` (one manager call: remove → swap → re-add) with the equivalent **manual rebalance** done
/// through the Uniswap v4 PositionManager + a swap router (decrease → swap → mint).
///
/// A fresh hookless WETH/USDC pool is used (initialized at a ~$3000/ETH tick if it does not already
/// exist), seeded with a wide background LP so the rebalancing swaps have depth. Env-gated: skips cleanly
/// when BASE_RPC is unset so CI without secrets stays green.
///
/// Run:
///   BASE_RPC=https://... [BASE_FORK_BLOCK=...] \
///     forge test --match-path test/GasCompareVolatile.fork.t.sol -vvv
contract GasCompareVolatileForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── Base mainnet (chainId 8453) v4 + token addresses ──
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address internal constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // 18dp, currency0
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6dp, currency1

    // ── Base Chainlink USD reference feeds (8 dp) ──
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_FEED = 0x458138Fc0D67027E9A6778ef40a6ffC318c69061;

    uint24 internal constant FEE = 3000;
    int24 internal constant TS = 60;
    int24 internal constant W = 600; // position half-width (10 * tickSpacing)

    PoolKey internal key;
    int24 internal baseTick; // current tick snapped to tickSpacing
    bool internal forkActive;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    address internal owner = makeAddr("vol_owner");
    address internal treasury = makeAddr("vol_treasury");
    address internal bot = makeAddr("vol_bot");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC unset; skipping Base fork gas comparison");
            return;
        }
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forkActive = true;

        key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: FEE,
            tickSpacing: TS,
            hooks: IHooks(address(0))
        });

        // Initialize the pool at the LIVE ETH/USD reference price (not a hard-coded tick) so a swap's
        // realized price tracks the Chainlink feed the operator oracle checks against — otherwise the
        // guard's `PriceOutOfBounds` would trip even on the happy path. Owner ops are price-agnostic, so
        // this is safe for the task_037 owner-driven benchmarks too. If the pool already exists we take
        // its (arbitraged, ~reference) price as-is.
        (uint160 sp,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sp == 0) POOL_MANAGER.initialize(key, _oracleSqrtPriceX96());
        (, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        baseTick = (tick / TS) * TS; // snap to tickSpacing

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        lpRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        _seedBackgroundLiquidity();
    }

    /// @dev sqrtPriceX96 for the WETH(0,18dp)/USDC(1,6dp) pool at the live ETH/USD feed price.
    /// price_raw = amount1/amount0 = usd * 1e6 / 1e18 = answer / 1e20  (answer is USD * 1e8);
    /// sqrtPriceX96 = sqrt(price_raw) << 96 = sqrt(price_raw * 2^192).
    function _oracleSqrtPriceX96() internal view returns (uint160) {
        (, int256 answer,,,) = IAggV3(ETH_USD_FEED).latestRoundData();
        require(answer > 0, "bad ETH/USD");
        uint256 ratioX192 = FullMath.mulDiv(uint256(answer), uint256(1) << 192, 1e20);
        return uint160(Math.sqrt(ratioX192));
    }

    // ────────── shared fixtures ──────────

    /// @dev Wide background LP so the manager/baseline rebalancing swaps trade against real depth.
    function _seedBackgroundLiquidity() internal {
        int24 lo = baseTick - 60_000;
        int24 hi = baseTick + 60_000;
        (uint160 sp,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint128 L = LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), 500e18, 1_500_000e6
        );
        deal(WETH, address(this), 1_000e18);
        deal(USDC, address(this), 3_000_000e6);
        IERC20Min(WETH).approve(address(lpRouter), type(uint256).max);
        IERC20Min(USDC).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(L)), salt: 0}), ""
        );
    }

    /// @dev Trade both directions so an in-range position accrues fees on both currencies.
    function _genFees() internal {
        address trader = makeAddr("trader");
        deal(WETH, trader, 50e18);
        deal(USDC, trader, 150_000e6);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.startPrank(trader);
        IERC20Min(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Min(USDC).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ts,
                ""
            );
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: false, amountSpecified: -3_000e6, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ts,
                ""
            );
        }
        vm.stopPrank();
    }

    function _initParams() internal view returns (VolatileLPManager.InitParams memory p) {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = key;
        p = VolatileLPManager.InitParams({
            owner: owner, name: bytes32("Envelop VolLP"), descriptor: address(0), pools: pools
        });
    }

    function _allocLeg(bytes32 salt) internal view returns (VolatileLPManager.VolatileAllocLeg[] memory legs) {
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = VolatileLPManager.VolatileAllocLeg({
            poolId: key.toId(),
            salt: salt,
            tickLower: baseTick - W,
            tickUpper: baseTick + W,
            zeroForOne: false,
            swapAmountIn: 0, // pure add (owner may add a pre-swap; kept out to isolate add gas)
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: 1e18, // ~1 WETH
            amount1Desired: 3_000e6, // ~3000 USDC
            minLiquidity: 0
        });
    }

    // ────────── smoke ──────────

    function test_smoke_baseLive() public view {
        if (!forkActive) return;
        assertGt(address(POOL_MANAGER).code.length, 0, "PoolManager code");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager code");
        assertGt(PERMIT2.code.length, 0, "Permit2 code");
        assertGt(WETH.code.length, 0, "WETH code");
        assertGt(USDC.code.length, 0, "USDC code");
    }

    // ────────── all manager ops gas ──────────

    function test_volatile_managerOps_gas() public {
        if (!forkActive) return;

        VolatileLPManager impl = new VolatileLPManager(POOL_MANAGER, treasury);
        LPManagerFactory factory = FactoryHelper.single(address(this), address(impl));

        uint256 g = gasleft();
        VolatileLPManager mgr = FactoryHelper.cloneVolatile(factory, address(impl), _initParams());
        uint256 gCreate = g - gasleft();

        deal(WETH, address(mgr), 10e18);
        deal(USDC, address(mgr), 30_000e6);

        bytes32 s1 = bytes32(uint256(1));
        bytes32 s2 = bytes32(uint256(2));

        // allocate (position s1, measured)
        vm.prank(owner);
        g = gasleft();
        mgr.allocate(_allocLeg(s1));
        uint256 gAllocate = g - gasleft();
        // a second position (s2) for the withdraw benchmark
        vm.prank(owner);
        mgr.allocate(_allocLeg(s2));

        // claimFees (after accruing fees)
        _genFees();
        vm.prank(owner);
        g = gasleft();
        mgr.claimFees(s1);
        uint256 gClaim = g - gasleft();

        // recenter s1 to a shifted range (remove → swap → re-add, one call)
        VolatileLPManager.RecenterParams memory rp = VolatileLPManager.RecenterParams({
            salt: s1,
            newTickLower: baseTick,
            newTickUpper: baseTick + 2 * W,
            zeroForOne: true,
            swapAmountIn: 0.1e18,
            swapPriceLimit: TickMath.MIN_SQRT_PRICE + 1,
            minAmountOut: 0,
            minLiquidity: 0
        });
        vm.prank(owner);
        g = gasleft();
        mgr.recenter(rp);
        uint256 gRecenter = g - gasleft();

        // withdrawTo (drain s2 to a recipient)
        uint128 liq2 = mgr.positionOf(s2).liquidity;
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: s2, liquidityToPull: liq2});
        BaseLPManager.WithdrawToParams memory wp = BaseLPManager.WithdrawToParams({
            recipient: makeAddr("recipient"),
            requestedCurrency: Currency.wrap(USDC),
            amount: 50e6,
            pulls: pulls,
            swaps: new BaseLPManager.WithdrawSwap[](0)
        });
        vm.prank(owner);
        g = gasleft();
        mgr.withdrawTo(wp);
        uint256 gWithdraw = g - gasleft();

        console2.log("== VolatileLPManager ops (Base fork) ==");
        console2.log("  createManager      ", gCreate);
        console2.log("  allocate           ", gAllocate);
        console2.log("  claimFees          ", gClaim);
        console2.log("  recenter           ", gRecenter);
        console2.log("  withdrawTo         ", gWithdraw);
    }

    // ────────── recenter vs manual rebalance via Uniswap PositionManager ──────────

    function test_recenter_vs_manualRebalance() public {
        if (!forkActive) return;

        // ── A) VolatileLPManager.recenter (one call) ──
        VolatileLPManager impl = new VolatileLPManager(POOL_MANAGER, treasury);
        LPManagerFactory factory = FactoryHelper.single(address(this), address(impl));
        VolatileLPManager mgr = FactoryHelper.cloneVolatile(factory, address(impl), _initParams());
        deal(WETH, address(mgr), 10e18);
        deal(USDC, address(mgr), 30_000e6);
        bytes32 s1 = bytes32(uint256(1));
        vm.prank(owner);
        mgr.allocate(_allocLeg(s1));

        VolatileLPManager.RecenterParams memory rp = VolatileLPManager.RecenterParams({
            salt: s1,
            newTickLower: baseTick,
            newTickUpper: baseTick + 2 * W,
            zeroForOne: true,
            swapAmountIn: 0.1e18,
            swapPriceLimit: TickMath.MIN_SQRT_PRICE + 1,
            minAmountOut: 0,
            minLiquidity: 0
        });
        vm.prank(owner);
        uint256 g = gasleft();
        mgr.recenter(rp);
        uint256 gRecenter = g - gasleft();

        // ── B) Manual rebalance via v4 PositionManager: decrease(all) → swap → mint(new range) ──
        uint256 gManual = _manualRebalance();

        console2.log("== recenter vs manual rebalance (Base fork) ==");
        console2.log("  VolatileLPManager.recenter (1 call)          ", gRecenter);
        console2.log("  manual: PositionManager decrease+swap+mint   ", gManual);
        if (gManual > gRecenter) {
            console2.log("  manual costs MORE by                         ", gManual - gRecenter);
        } else {
            console2.log("  manual costs LESS by                         ", gRecenter - gManual);
        }
    }

    /// @dev The by-hand equivalent of a recenter for an EOA position: mint a position, then rebalance it
    /// = decrease all liquidity + take, swap to rebalance, mint at the new range. Returns the rebalance gas.
    function _manualRebalance() internal returns (uint256 gManual) {
        address eoa = makeAddr("baseline_eoa");
        IPositionManager posm = IPositionManager(POSITION_MANAGER);

        deal(WETH, eoa, 10e18);
        deal(USDC, eoa, 30_000e6);
        deal(WETH, eoa, 10e18);

        vm.startPrank(eoa);
        _permit2Approve(WETH);
        _permit2Approve(USDC);

        // Pre: mint the position to rebalance.
        uint256 tokenId = posm.nextTokenId();
        (uint128 L, int24 lo, int24 hi) = _liq(baseTick - W, baseTick + W, 1e18, 3_000e6);
        _mint(posm, lo, hi, L, eoa);
        vm.stopPrank();

        // Rebalance (measured): decrease all + take, swap, mint at the new range.
        uint256 g = gasleft();
        vm.startPrank(eoa);
        Plan memory dp = Planner.init();
        dp = dp.add(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(L), uint128(0), uint128(0), bytes("")));
        dp = dp.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, eoa));
        posm.modifyLiquidities(dp.encode(), block.timestamp + 60);
        vm.stopPrank();

        _swapExactIn(true, 0.1e18); // rebalance swap: 0.1 WETH → USDC (eoa pays)

        vm.startPrank(eoa);
        (uint128 L2, int24 lo2, int24 hi2) = _liq(baseTick, baseTick + 2 * W, 1e18, 3_000e6);
        _mint(posm, lo2, hi2, L2, eoa);
        vm.stopPrank();
        gManual = g - gasleft();
    }

    // ────────── operator path gated by a real Chainlink oracle ──────────

    /// @dev A fresh manager with one allocated position at `salt` (owner-driven), funded for a recenter.
    function _freshManagerWithPosition(bytes32 salt) internal returns (VolatileLPManager mgr) {
        VolatileLPManager impl = new VolatileLPManager(POOL_MANAGER, treasury);
        LPManagerFactory factory = FactoryHelper.single(address(this), address(impl));
        mgr = FactoryHelper.cloneVolatile(factory, address(impl), _initParams());
        deal(WETH, address(mgr), 10e18);
        deal(USDC, address(mgr), 30_000e6);
        vm.prank(owner);
        mgr.allocate(_allocLeg(salt));
    }

    /// @dev A recenter to a shifted range with a small (fee-dominated) WETH->USDC rebalancing swap.
    function _recenterParams(bytes32 salt) internal view returns (VolatileLPManager.RecenterParams memory) {
        return VolatileLPManager.RecenterParams({
            salt: salt,
            newTickLower: baseTick,
            newTickUpper: baseTick + 2 * W,
            zeroForOne: true,
            swapAmountIn: 0.1e18,
            swapPriceLimit: TickMath.MIN_SQRT_PRICE + 1,
            minAmountOut: 0,
            minLiquidity: 0
        });
    }

    /// @dev Deploy the real {ChainlinkPriceOracle} wired to the live Base ETH/USD + USDC/USD feeds. A
    /// large heartbeat keeps the fork-block answers "fresh" so `check` returns `enforced = true`.
    function _chainlinkOracle(uint16 maxDevBps) internal returns (ChainlinkPriceOracle oracle) {
        oracle = new ChainlinkPriceOracle(address(this), maxDevBps);
        oracle.setFeed(Currency.wrap(WETH), ETH_USD_FEED, 365 days, 18);
        oracle.setFeed(Currency.wrap(USDC), USDC_USD_FEED, 365 days, 6);
    }

    /// @notice Operator recenter fail-closed behind the real Chainlink oracle (the H-VOL-1 path). Happy
    /// path: a small swap's realized price is within tolerance of the ETH/USD reference, so the oracle
    /// vouches. Logs the oracle overhead vs the owner (bypassed) recenter.
    function test_operator_withChainlinkOracle_gas() public {
        if (!forkActive) return;

        VolatileLPManager impl = new VolatileLPManager(POOL_MANAGER, treasury);
        LPManagerFactory factory = FactoryHelper.single(address(this), address(impl));
        VolatileLPManager mgr = FactoryHelper.cloneVolatile(factory, address(impl), _initParams());
        deal(WETH, address(mgr), 10e18);
        deal(USDC, address(mgr), 30_000e6);

        bytes32 sOwner = bytes32(uint256(1));
        bytes32 sBot = bytes32(uint256(2));
        vm.startPrank(owner);
        mgr.allocate(_allocLeg(sOwner));
        mgr.allocate(_allocLeg(sBot));
        vm.stopPrank();

        // Baseline: owner recenter (oracle bypassed — full freedom).
        vm.prank(owner);
        uint256 g = gasleft();
        mgr.recenter(_recenterParams(sOwner));
        uint256 gOwner = g - gasleft();

        // Wire the real Chainlink oracle (5% tolerance) + an operator bot.
        ChainlinkPriceOracle oracle = _chainlinkOracle(500);
        vm.startPrank(owner);
        mgr.setPriceOracle(address(oracle));
        mgr.setOperator(bot, true);
        vm.stopPrank();

        // Operator recenter: small swap, realized price ~= reference (fee only) -> oracle vouches.
        vm.prank(bot);
        g = gasleft();
        mgr.recenter(_recenterParams(sBot));
        uint256 gOperator = g - gasleft();

        assertGt(mgr.positionOf(sOwner).liquidity, 0, "owner recenter");
        assertGt(mgr.positionOf(sBot).liquidity, 0, "operator recenter");

        console2.log("== operator + Chainlink oracle recenter (Base fork) ==");
        console2.log("  owner recenter (oracle bypassed)   ", gOwner);
        console2.log("  operator recenter (oracle-gated)   ", gOperator);
        console2.log("  oracle overhead                    ", gOperator > gOwner ? gOperator - gOwner : 0);
    }

    /// @notice With no oracle set, an operator swap is fail-closed (`OperatorSwapGuardRequired`).
    function test_operator_swap_withoutOracle_reverts() public {
        if (!forkActive) return;
        bytes32 s = bytes32(uint256(1));
        VolatileLPManager mgr = _freshManagerWithPosition(s);
        vm.prank(owner);
        mgr.setOperator(bot, true);
        // priceOracle unset -> operator cannot self-authorize a swap.
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        mgr.recenter(_recenterParams(s));
    }

    /// @notice An operator swap whose realized price deviates beyond tolerance reverts `PriceOutOfBounds`.
    /// A tight (10 bps) tolerance makes this deterministic on a fork: the 0.3% pool fee alone pushes the
    /// realized output below the reference-implied bound, standing in for an adverse (sandwichable) swap.
    function test_operator_swap_outOfBounds_reverts() public {
        if (!forkActive) return;
        bytes32 s = bytes32(uint256(1));
        VolatileLPManager mgr = _freshManagerWithPosition(s);
        ChainlinkPriceOracle oracle = _chainlinkOracle(10); // 0.10% tolerance
        vm.startPrank(owner);
        mgr.setPriceOracle(address(oracle));
        mgr.setOperator(bot, true);
        vm.stopPrank();
        vm.prank(bot);
        // `PriceOutOfBounds` carries (amountOut, minOut) args — match on the selector only.
        vm.expectPartialRevert(ChainlinkPriceOracle.PriceOutOfBounds.selector);
        mgr.recenter(_recenterParams(s));
    }

    // ────────── PositionManager / swap helpers ──────────

    function _permit2Approve(address token) internal {
        IERC20Min(token).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, type(uint48).max);
    }

    function _liq(int24 lo, int24 hi, uint256 amt0, uint256 amt1) internal view returns (uint128 L, int24, int24) {
        (uint160 sp,,,) = POOL_MANAGER.getSlot0(key.toId());
        L = LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amt0, amt1
        );
        return (L, lo, hi);
    }

    function _mint(IPositionManager posm, int24 lo, int24 hi, uint128 L, address to) internal {
        Plan memory plan = Planner.init()
            .add(
                Actions.MINT_POSITION,
                abi.encode(key, lo, hi, uint256(L), type(uint128).max, type(uint128).max, to, bytes(""))
            );
        posm.modifyLiquidities(plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp + 60);
    }

    function _swapExactIn(bool zeroForOne, uint256 amtIn) internal {
        address caller = makeAddr("baseline_eoa");
        vm.startPrank(caller);
        IERC20Min(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Min(USDC).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amtIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }
}
