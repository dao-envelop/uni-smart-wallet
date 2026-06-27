// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Planner, Plan} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Minimal USDT-safe v4 swap router for the fork test: settles the input from its OWN
/// (test-dealt) balance via the production CurrencyLibrary.transfer, takes the output to `recipient`.
/// (PoolSwapTest can't pay USDT.)
contract ForkSwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amtIn, address recipient) external {
        PM.unlock(abi.encode(key, zeroForOne, amtIn, recipient));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "only pm");
        (PoolKey memory key, bool z, uint256 amtIn, address recipient) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta delta = PM.swap(
            key,
            SwapParams({
                zeroForOne: z,
                amountSpecified: -int256(amtIn),
                sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        Currency inC = z ? key.currency0 : key.currency1;
        Currency outC = z ? key.currency1 : key.currency0;
        int128 inDelta = z ? delta.amount0() : delta.amount1(); // negative (owed)
        int128 outDelta = z ? delta.amount1() : delta.amount0(); // positive (credit)
        PM.sync(inC);
        inC.transfer(address(PM), uint256(uint128(-inDelta))); // pay from own dealt balance — USDT-safe
        PM.settle();
        PM.take(outC, recipient, uint256(uint128(outDelta)));
        return "";
    }
}

interface IStateViewMin {
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity);
}

/// @notice Mainnet-fork gas comparison: StableLPManager vs Uniswap v4 PositionManager.
/// Skips when MAINNET_RPC is unset so default CI stays green.
contract GasCompareStableLPForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // ── Mainnet v4 + token addresses (verified to have code on fork) ──
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IStateViewMin constant STATE_VIEW = IStateViewMin(0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227);

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6dp
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6dp
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18dp

    // The three stable pools (all fee=100, tickSpacing=1, hooks=0).
    PoolKey internal kUSDCUSDT; // USDC/USDT
    PoolKey internal kDAIUSDC; // DAI/USDC
    PoolKey internal kDAIUSDT; // DAI/USDT

    bool internal forkActive;
    PoolSwapTest internal swapRouter;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "MAINNET_RPC unset; skipping fork gas comparison");
            return;
        }
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forkActive = true;

        kUSDCUSDT = _key(USDC, USDT);
        kDAIUSDC = _key(DAI, USDC);
        kDAIUSDT = _key(DAI, USDT);

        swapRouter = new PoolSwapTest(POOL_MANAGER);
    }

    // Generate fee volume with NON-USDT inputs only (PoolSwapTest pays the input token via the test
    // CurrencySettler, which can't pay USDT). Enough to accrue fees to in-range positions.
    function _genFees() internal {
        address trader = makeAddr("trader");
        deal(USDC, trader, 2_000e6);
        deal(DAI, trader, 2_000e18);
        vm.startPrank(trader);
        IERC20Min(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Min(DAI).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 3; ++i) {
            _swapExactIn(kUSDCUSDT, USDC, 200e6); // USDC→USDT (pay USDC)
            _swapExactIn(kDAIUSDC, DAI, 200e18); // DAI→USDC
            _swapExactIn(kDAIUSDC, USDC, 200e6); // USDC→DAI (bidirectional on the no-USDT pool)
            _swapExactIn(kDAIUSDT, DAI, 200e18); // DAI→USDT (pay DAI)
        }
        vm.stopPrank();
    }

    function _swapExactIn(PoolKey memory k, address tokenIn, uint256 amtIn) internal {
        bool zeroForOne = Currency.unwrap(k.currency0) == tokenIn;
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amtIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _reinvestLeg(PoolKey memory k) internal pure returns (StableLPManager.AllocLeg memory) {
        return StableLPManager.AllocLeg({
            poolId: k.toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: 0, // reinvest sizes the add from realized fee deltas
            amount1Desired: 0,
            minLiquidity: 0
        });
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function test_smoke_poolsLive() public view {
        if (!forkActive) return;
        assertGt(address(POOL_MANAGER).code.length, 0, "PoolManager code");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager code");
        assertGt(PERMIT2.code.length, 0, "Permit2 code");
        assertGt(address(STATE_VIEW).code.length, 0, "StateView code");
        assertGt(USDT.code.length, 0, "USDT code");

        _logPool("USDC/USDT", kUSDCUSDT);
        _logPool("DAI/USDC", kDAIUSDC);
        _logPool("DAI/USDT", kDAIUSDT);
    }

    function _logPool(string memory name, PoolKey memory k) internal view {
        PoolId id = k.toId();
        (uint160 sp, int24 tick,,) = STATE_VIEW.getSlot0(id);
        uint128 L = STATE_VIEW.getLiquidity(id);
        console2.log(name);
        console2.log("  tick", tick);
        console2.log("  sqrtP", sp);
        console2.log("  liquidity", L);
        assertGt(L, 0, "pool has liquidity");
    }

    // ───────────────────────── StableLP path ─────────────────────────

    uint256 constant FUND = 100e6; // 100 USDT
    int24 constant W = 50; // half-width of the position range (ts=1)

    function test_stableLP_path() public {
        if (!forkActive) return;
        address owner = makeAddr("slp_owner");
        address treasury = makeAddr("slp_treasury");

        StableLPManager impl = new StableLPManager(POOL_MANAGER, treasury);
        StableLPFactory factory = new StableLPFactory(address(impl));

        // ── createManager (measured separately) ──
        StableLPManager.InitParams memory ip = _initParams(owner);
        uint256 g = gasleft();
        StableLPManager mgr = StableLPManager(payable(factory.createManager(ip)));
        uint256 gCreate = g - gasleft();

        // ── deposit: plain USDT transfer to the manager ──
        deal(USDT, owner, FUND);
        vm.startPrank(owner);
        g = gasleft();
        (bool ok,) = USDT.call(abi.encodeWithSignature("transfer(address,uint256)", address(mgr), FUND));
        uint256 gDeposit = g - gasleft();
        require(ok, "usdt transfer");

        // ── allocate: 3 legs, cross-leg netting (USDT→USDC surplus funds DAI/USDC) ──
        StableLPManager.AllocLeg[] memory legs = _legs();
        g = gasleft();
        mgr.allocate(legs);
        uint256 gAllocate = g - gasleft();
        vm.stopPrank();

        // sanity: a position opened in each pool, ~all USDT consumed
        assertEq(mgr.openPositionCount(), 3, "three positions");
        assertGt(mgr.positionOf(_saltOf(kUSDCUSDT)).liquidity, 0, "USDC/USDT funded");
        assertGt(mgr.positionOf(_saltOf(kDAIUSDC)).liquidity, 0, "DAI/USDC funded");
        assertGt(mgr.positionOf(_saltOf(kDAIUSDT)).liquidity, 0, "DAI/USDT funded");
        uint256 usdtLeft = IERC20Min(USDT).balanceOf(address(mgr));
        assertLt(usdtLeft, FUND / 10, "at least ~90% USDT deployed");

        // ── reinvest: accrue fees, then compound each pool ──
        _genFees();
        PoolKey[3] memory ks = [kUSDCUSDT, kDAIUSDT, kDAIUSDC];
        vm.startPrank(owner);
        g = gasleft();
        for (uint256 i = 0; i < 3; ++i) {
            mgr.reinvest(_reinvestLeg(ks[i]));
        }
        uint256 gReinvest = g - gasleft();
        vm.stopPrank();

        console2.log("== StableLP ==");
        console2.log("  createManager", gCreate);
        console2.log("  deposit", gDeposit);
        console2.log("  allocate(3, incl swaps)", gAllocate);
        console2.log("  reinvest(3)", gReinvest);
        console2.log("  TOTAL (excl create)", gDeposit + gAllocate + gReinvest);
        console2.log("  USDT left (dust)", usdtLeft);
    }

    function _initParams(address owner) internal view returns (StableLPManager.InitParams memory p) {
        StableLPManager.PoolConfig[] memory cfgs = new StableLPManager.PoolConfig[](3);
        cfgs[0] = _cfg(kUSDCUSDT);
        cfgs[1] = _cfg(kDAIUSDT);
        cfgs[2] = _cfg(kDAIUSDC);
        p = StableLPManager.InitParams({owner: owner, pools: cfgs});
    }

    function _cfg(PoolKey memory k) internal view returns (StableLPManager.PoolConfig memory) {
        (, int24 tick,,) = STATE_VIEW.getSlot0(k.toId());
        return StableLPManager.PoolConfig({key: k, tickLower: tick - W, tickUpper: tick + W});
    }

    // Legs ordered so the USDC/USDT leg's surplus USDC funds the later DAI/USDC leg.
    function _legs() internal view returns (StableLPManager.AllocLeg[] memory legs) {
        legs = new StableLPManager.AllocLeg[](3);
        uint160 maxLimit = TickMath.MAX_SQRT_PRICE - 1; // oneForZero (input is currency1)
        // Leg 0: USDC/USDT — swap 49 USDT→USDC (16 for here + ~33 surplus for DAI/USDC), LP 16/16.
        legs[0] = StableLPManager.AllocLeg({
            poolId: kUSDCUSDT.toId(),
            zeroForOne: false, // USDT(c1) → USDC(c0)
            swapAmountIn: 49e6,
            swapPriceLimit: maxLimit,
            amount0Desired: 16e6, // USDC
            amount1Desired: 16e6, // USDT
            minLiquidity: 0
        });
        // Leg 1: DAI/USDT — swap 16 USDT→DAI, LP ~15 DAI / 15 USDT.
        legs[1] = StableLPManager.AllocLeg({
            poolId: kDAIUSDT.toId(),
            zeroForOne: false, // USDT(c1) → DAI(c0)
            swapAmountIn: 16e6,
            swapPriceLimit: maxLimit,
            amount0Desired: 15e18, // DAI
            amount1Desired: 15e6, // USDT
            minLiquidity: 0
        });
        // Leg 2: DAI/USDC — swap 16 surplus USDC→DAI, LP ~15 DAI / 15 USDC.
        legs[2] = StableLPManager.AllocLeg({
            poolId: kDAIUSDC.toId(),
            zeroForOne: false, // USDC(c1) → DAI(c0)
            swapAmountIn: 16e6,
            swapPriceLimit: maxLimit,
            amount0Desired: 15e18, // DAI
            amount1Desired: 15e6, // USDC
            minLiquidity: 0
        });
    }

    function _saltOf(PoolKey memory k) internal pure returns (bytes32) {
        return PoolId.unwrap(k.toId());
    }

    // ───────────────────────── Baseline: Uniswap v4 PositionManager ─────────────────────────

    function test_baseline_path() public {
        if (!forkActive) return;
        address eoa = makeAddr("baseline_eoa");
        IPositionManager posm = IPositionManager(POSITION_MANAGER);
        ForkSwapRouter router = new ForkSwapRouter(POOL_MANAGER);

        // Generous balances (post-swap holdings); swaps are measured separately below.
        deal(USDT, eoa, 200e6);
        deal(USDC, eoa, 200e6);
        deal(DAI, eoa, 200e18);
        // Router pays the swap inputs from its own balance.
        deal(USDT, address(router), 65e6);
        deal(USDC, address(router), 16e6);

        // ── swaps: 3 representative v4 swaps (USDT→USDC, USDT→DAI, USDC→DAI) ──
        uint256 g = gasleft();
        router.swap(kUSDCUSDT, Currency.unwrap(kUSDCUSDT.currency0) == USDT, 49e6, eoa);
        router.swap(kDAIUSDT, Currency.unwrap(kDAIUSDT.currency0) == USDT, 16e6, eoa);
        router.swap(kDAIUSDC, Currency.unwrap(kDAIUSDC.currency0) == USDC, 16e6, eoa);
        uint256 gSwaps = g - gasleft();

        vm.startPrank(eoa);
        _permit2Approve(USDT);
        _permit2Approve(USDC);
        _permit2Approve(DAI);

        // ── mint 3 positions ──
        uint256 firstId = posm.nextTokenId();
        g = gasleft();
        _mint(posm, kUSDCUSDT, eoa, 16e6, 16e6);
        _mint(posm, kDAIUSDT, eoa, 15e18, 15e6);
        _mint(posm, kDAIUSDC, eoa, 15e18, 15e6);
        uint256 gMint = g - gasleft();
        vm.stopPrank();

        // ── reinvest: accrue fees, then collect + compound each position ──
        _genFees();
        PoolKey[3] memory ks = [kUSDCUSDT, kDAIUSDT, kDAIUSDC];
        vm.startPrank(eoa);
        g = gasleft();
        for (uint256 i = 0; i < 3; ++i) {
            _collectAndCompound(posm, firstId + i, ks[i]);
        }
        uint256 gReinvest = g - gasleft();
        vm.stopPrank();

        console2.log("== Uniswap v4 PositionManager ==");
        console2.log("  swaps(3)", gSwaps);
        console2.log("  mint(3)", gMint);
        console2.log("  reinvest collect+compound(3)", gReinvest);
        console2.log("  TOTAL", gSwaps + gMint + gReinvest);
    }

    function _permit2Approve(address token) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", PERMIT2, type(uint256).max));
        require(ok, "permit2 approve");
        IAllowanceTransfer(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, type(uint48).max);
    }

    function _liq(PoolKey memory k, uint256 amt0, uint256 amt1)
        internal
        view
        returns (uint128 L, int24 lower, int24 upper)
    {
        (uint160 sqrtP, int24 tick,,) = STATE_VIEW.getSlot0(k.toId());
        lower = tick - W;
        upper = tick + W;
        L = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amt0, amt1
        );
    }

    function _mintParams(PoolKey memory k, int24 lo, int24 hi, uint128 L, uint256 a0, uint256 a1, address owner)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(k, lo, hi, uint256(L), uint128(a0 * 4), uint128(a1 * 4), owner, bytes(""));
    }

    function _mint(IPositionManager posm, PoolKey memory k, address owner, uint256 amt0, uint256 amt1) internal {
        (uint128 L, int24 lo, int24 hi) = _liq(k, amt0, amt1);
        Plan memory plan = Planner.init().add(Actions.MINT_POSITION, _mintParams(k, lo, hi, L, amt0, amt1, owner));
        posm.modifyLiquidities(plan.finalizeModifyLiquidityWithSettlePair(k), block.timestamp + 60);
    }

    function _collectAndCompound(IPositionManager posm, uint256 tokenId, PoolKey memory k) internal {
        // collect: DECREASE 0 then take both sides to the owner
        Plan memory cp = Planner.init();
        cp = cp.add(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")));
        cp = cp.add(Actions.TAKE_PAIR, abi.encode(k.currency0, k.currency1, msg.sender));
        posm.modifyLiquidities(cp.encode(), block.timestamp + 60);

        // compound: increase by a small fixed liquidity (represents re-adding harvested fees)
        Plan memory ip = Planner.init();
        ip = ip.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(tokenId, uint256(1e6), type(uint128).max, type(uint128).max, bytes(""))
        );
        bytes memory data = ip.finalizeModifyLiquidityWithSettlePair(k);
        posm.modifyLiquidities(data, block.timestamp + 60);
    }
}
