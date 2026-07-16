// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests for StableLPManager against the live Base V4 PoolManager, exercising a
/// **non-stable pool: native ETH + USDC** (a configured pool currency does not have to be a stablecoin
/// — `initialize` only enforces hookless + valid ticks). Verifies that the native settle/take plumbing
/// (`allocate` paying ETH from the manager, `withdrawTo` delivering ETH straight to a recipient,
/// `claimFees` harvesting) works against the production PoolManager, not the in-test deploy.
///
/// The manager is the sole LP of a freshly-initialized hookless pool, so all swap fees accrue to it and
/// the (artificial) tick-0 price is irrelevant to the plumbing under test. Env-gated: skips cleanly if
/// BASE_RPC is unset so CI without secrets stays green.
///
/// Run:
///   BASE_RPC=https://... [BASE_FORK_BLOCK=...] \
///     forge test --match-path test/StableLPManager.fork.t.sol -vvv
contract StableLPManagerForkTest is Test {
    using StateLibrary for IPoolManager;

    // Base mainnet V4 deployment (chainId 8453) per script/chain_params.json.
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    Currency internal constant NATIVE = Currency.wrap(address(0)); // ETH == currency0 (0 < any token)
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Uncommon fee/spacing so a FRESH hookless pool is initialized at tick 0 (the manager is the sole
    // LP) instead of colliding with a real ETH/USDC pool already live on the fork.
    uint24 internal constant FEE = 543; // 0.0543% — not a canonical tier
    int24 internal constant SPACING = 11;
    int24 internal tickLower; // full range (set in setUp once SPACING is known)
    int24 internal tickUpper;

    StableLPManager internal mgr;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    PoolId internal poolId;
    bytes32 internal salt;

    address internal treasury = address(0xFEE5);
    address internal trader = address(0xCAFE);
    address internal recipient = address(0xBEEF);

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC unset; skipping fork tests");
            return;
        }

        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        forkActive = true;

        // Native ETH / USDC pool: currency0 = address(0) (native) < USDC = currency1.
        key = PoolKey({
            currency0: NATIVE, currency1: Currency.wrap(USDC), fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        poolId = key.toId();
        salt = PoolId.unwrap(poolId);

        tickLower = TickMath.minUsableTick(SPACING);
        tickUpper = TickMath.maxUsableTick(SPACING);

        (uint160 sp,,,) = POOL_MANAGER.getSlot0(poolId);
        if (sp == 0) {
            POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(0));
        }

        swapRouter = new PoolSwapTest(POOL_MANAGER);

        // Deploy the manager configured on the native/USDC pool; NFT mints to this test contract
        // (so `this` is both owner and operator for the calls below).
        StableLPManager impl = new StableLPManager(POOL_MANAGER, treasury);
        StableLPFactory factory = new StableLPFactory(address(impl));
        BaseLPManager.PoolConfig[] memory cfgs = new BaseLPManager.PoolConfig[](1);
        cfgs[0] = BaseLPManager.PoolConfig({key: key, tickLower: tickLower, tickUpper: tickUpper});
        mgr = StableLPManager(
            payable(factory.createManager(
                    BaseLPManager.InitParams({owner: address(this), name: bytes32("Envelop ETH-USDC"), pools: cfgs})
                ))
        );

        // Fund the manager with native ETH + USDC.
        vm.deal(address(mgr), 100 ether);
        deal(USDC, address(mgr), 1_000_000e6);

        // Fund the trader for fee-generating swaps.
        vm.deal(trader, 100 ether);
        deal(USDC, trader, 1_000_000e6);
        vm.prank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
    }

    // ────────── helpers ──────────

    function _leg(uint256 ethAmt, uint256 usdcAmt) internal view returns (BaseLPManager.AllocLeg[] memory legs) {
        legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: poolId,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: ethAmt, // native side
            amount1Desired: usdcAmt, // USDC side
            minLiquidity: 0
        });
    }

    /// @dev exactIn swap; native input (zeroForOne) is paid as msg.value, USDC input via approval.
    function _swap(bool zeroForOne, uint256 amountIn) internal {
        uint256 value = zeroForOne ? amountIn : 0; // currency0 (native) is the input when zeroForOne
        vm.prank(trader);
        swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _usdc(address who) internal view returns (uint256) {
        return IERC20(USDC).balanceOf(who);
    }

    // ────────── tests ──────────

    /// A manager CAN be created on a non-stable (native ETH / USDC) pool, and `allocate` settles the
    /// native side straight from the manager's ETH balance against the live PoolManager.
    function test_fork_stablePlusNative_create_and_allocate() public {
        if (!forkActive) return;

        assertTrue(mgr.isManagedStable(NATIVE), "native is a managed currency");
        assertTrue(mgr.isManagedStable(Currency.wrap(USDC)), "USDC is a managed currency");

        uint256 ethBefore = address(mgr).balance;
        uint256 usdcBefore = _usdc(address(mgr));

        // Fresh pool at tick 0 (price 1 in raw units): balanced raw amounts ⇒ both sides are consumed.
        mgr.allocate(_leg(1e9, 1e9)); // owner == this

        assertGt(mgr.positionOf(salt).liquidity, 0, "native-pair position opened on live PoolManager");
        assertLt(address(mgr).balance, ethBefore, "native (ETH) settled from manager balance");
        assertLt(_usdc(address(mgr)), usdcBefore, "USDC settled from manager balance");
    }

    /// `withdrawTo` delivers native ETH straight from the PoolManager to an arbitrary recipient,
    /// bypassing the manager's balance — on the live PoolManager.
    function test_fork_stablePlusNative_withdrawTo_deliversNative() public {
        if (!forkActive) return;

        mgr.allocate(_leg(1e9, 1e9));

        uint256 amount = 5e8; // below the native principal freed by the full pull
        uint256 recipBefore = recipient.balance;

        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({poolId: poolId, liquidityToPull: mgr.positionOf(salt).liquidity});

        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: recipient,
                requestedStable: NATIVE,
                amount: amount,
                pulls: pulls,
                swaps: new BaseLPManager.WithdrawSwap[](0),
                reinvestRemainder: false
            })
        );

        assertEq(recipient.balance - recipBefore, amount, "recipient received native ETH straight from PoolManager");
        assertEq(mgr.positionOf(salt).liquidity, 0, "position fully pulled");
    }

    /// Real two-directional swap volume accrues fees to the manager's native/USDC position; `claimFees`
    /// harvests them to the manager (principal untouched) against the live PoolManager.
    function test_fork_stablePlusNative_claimFees() public {
        if (!forkActive) return;

        mgr.allocate(_leg(1e9, 1e9));
        uint128 liqBefore = mgr.positionOf(salt).liquidity;

        // Swap both ways, small vs the position's liquidity so they stay in (full) range and accrue fees.
        _swap(false, 1e6); // USDC -> ETH
        _swap(true, 1e6); // ETH -> USDC (native input, paid as value)

        uint256 ethBefore = address(mgr).balance;
        uint256 usdcBefore = _usdc(address(mgr));

        mgr.claimFees(salt);

        assertEq(mgr.positionOf(salt).liquidity, liqBefore, "principal untouched by claimFees");
        bool grew = address(mgr).balance > ethBefore || _usdc(address(mgr)) > usdcBefore;
        assertTrue(grew, "claimed fees landed on the manager (native and/or USDC)");
    }
}
