// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";
import {MockERC20, MockFeeOnTransferERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice PoC for audit finding **H-2**: the manager's V4 settle / `withdrawTo` delivery accounting
/// assumes `received == sent`. A managed stable that activates a transfer fee AFTER positions exist
/// (e.g. a USDT-style configurable fee turned on, or a rebasing "stable") breaks that assumption:
///  - the `withdrawTo` delivery path silently under-delivers (the recipient gets `amount - fee` while
///    the contract reports success) → **value lost**;
///  - the `allocate` settle path under-pays the PoolManager → `CurrencyNotSettled` revert → the
///    position can no longer be topped up / the freed funds can't be redeployed → **DoS on the stable**.
///
/// The pool is built and the position is opened while `feeBps == 0` (token behaves normally), then the
/// fee is flipped on — modelling the real-world "fee toggled on later" scenario. There is NO on-chain
/// guard against this in `initialize`; the only defence is curating the stable set off-chain.
contract StableLPManagerH2FeeOnTransferPoC is Test {
    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    StableLPManager internal impl;
    StableLPFactory internal factory;
    StableLPManager internal mgr;

    MockFeeOnTransferERC20 internal fot; // a "stable" that can switch on a transfer fee
    MockERC20 internal usd; // a normal counterpart stable
    Currency internal cFot;
    Currency internal cUsd;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = address(0xA11CE);
    address internal recipient = address(0xBEEF);
    address internal lp = address(0xABCD);
    address internal treasury = address(0xFEE5);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        fot = new MockFeeOnTransferERC20(); // feeBps == 0 for now
        usd = new MockERC20();
        cFot = Currency.wrap(address(fot));
        cUsd = Currency.wrap(address(usd));

        // Sorted hookless pool, initialized at 1:1.
        (Currency c0, Currency c1) = Currency.unwrap(cFot) < Currency.unwrap(cUsd) ? (cFot, cUsd) : (cUsd, cFot);
        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolId = key.toId();
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Seed deep liquidity while the fee is OFF (so settlement of the seed is exact).
        uint256 seed = 2_000_000e18;
        fot.mint(lp, seed);
        usd.mint(lp, seed);
        vm.startPrank(lp);
        fot.approve(address(lpRouter), type(uint256).max);
        usd.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();

        // Deploy the manager configured on the FOT/USD pool.
        impl = new StableLPManager(IPoolManager(address(poolManager)), treasury);
        factory = new StableLPFactory(address(impl));
        StableLPManager.StablePoolInit[] memory cfgs = new StableLPManager.StablePoolInit[](1);
        cfgs[0] = StableLPManager.StablePoolInit({key: key, tickLower: TL, tickUpper: TU});
        mgr = StableLPManager(
            payable(factory.createManager(
                    StableLPManager.InitParams({
                        owner: owner, name: bytes32("FOT"), descriptor: address(0), pools: cfgs
                    })
                ))
        );

        // Fund + open a position while the token still behaves like a plain ERC-20.
        fot.mint(address(mgr), 100_000e18);
        usd.mint(address(mgr), 100_000e18);
        vm.prank(owner);
        mgr.allocate(_balancedLeg());
        assertGt(mgr.positionOf(PoolId.unwrap(poolId)).liquidity, 0, "position opened (fee off)");
    }

    /// @dev A no-pre-swap leg that LPs both already-held sides (works cleanly while fee == 0).
    function _balancedLeg() internal view returns (BaseLPManager.AllocLeg[] memory legs) {
        legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: poolId,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: 10_000e18,
            amount1Desired: 10_000e18,
            minLiquidity: 0
        });
    }

    function _pullAll() internal view returns (BaseLPManager.WithdrawToParams memory p) {
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({
            salt: PoolId.unwrap(poolId), liquidityToPull: mgr.positionOf(PoolId.unwrap(poolId)).liquidity
        });
        p = BaseLPManager.WithdrawToParams({
            recipient: recipient,
            requestedCurrency: cFot,
            amount: 5_000e18,
            pulls: pulls,
            swaps: new BaseLPManager.WithdrawSwap[](0)
        });
    }

    // ────────── tests ──────────

    /// Delivery path silently under-delivers once the fee is on: `withdrawTo` "succeeds" but the
    /// recipient receives strictly less than the requested `amount` — value lost, no revert/signal.
    function test_H2_withdrawTo_silentlyUnderDelivers() public {
        fot.setFeeBps(100); // 1% transfer fee switches on

        uint256 before = fot.balanceOf(recipient);
        BaseLPManager.WithdrawToParams memory p = _pullAll();

        vm.prank(owner);
        mgr.withdrawTo(p); // does NOT revert — the v4 `currencyDelta` guard sees the full amount

        uint256 delivered = fot.balanceOf(recipient) - before;
        emit log_named_uint("requested", p.amount);
        emit log_named_uint("delivered", delivered);
        assertLt(delivered, p.amount, "recipient silently received less than requested");
        // ~1% haircut, here ~50 tokens, lost to the fee sink on the delivery transfer.
        assertApproxEqRel(delivered, (p.amount * 99) / 100, 0.001e18, "delivered is amount minus the transfer fee");
    }

    /// Settle path breaks once the fee is on: re-allocating the fee-bearing stable under-pays the
    /// PoolManager, so the unlock reverts with CurrencyNotSettled — the stable can't be deployed.
    function test_H2_allocate_revertsOnSettleShortfall() public {
        fot.setFeeBps(100); // 1% transfer fee switches on

        // A pre-swap leg makes the manager owe the FOT side to the pool ⇒ `_settle` under-delivers.
        BaseLPManager.AllocLeg[] memory legs = new BaseLPManager.AllocLeg[](1);
        bool fotIsZero = Currency.unwrap(key.currency0) == Currency.unwrap(cFot);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: poolId,
            zeroForOne: fotIsZero, // spend FOT into the pool
            swapAmountIn: 10_000e18,
            swapPriceLimit: fotIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            minLiquidity: 0
        });

        vm.prank(owner);
        vm.expectRevert(); // CurrencyNotSettled — settle paid `amount - fee`, PoolManager wants `amount`
        mgr.allocate(legs);
    }
}
