// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {StableLPFactory} from "../src/StableLPFactory.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Native ETH support for StableLPManager: a configured pool can be an ETH/token pool
/// (native = Currency(address(0)) = currency0). `allocate` settles the native side from the manager's
/// ETH balance; `withdrawTo` delivers native straight to a recipient via the v4 `take`.
contract StableLPManagerNativeTest is Test {
    PoolManager internal poolManager;
    StableLPManager internal mgr;
    Currency internal constant NATIVE = Currency.wrap(address(0));
    Currency internal token; // currency1
    PoolKey internal key;
    bytes32 internal salt;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE5);
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    int24 internal constant TL = -60;
    int24 internal constant TU = 60;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        token = Currency.wrap(address(new MockERC20()));

        key = PoolKey({currency0: NATIVE, currency1: token, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        salt = PoolId.unwrap(key.toId());

        StableLPManager impl = new StableLPManager(IPoolManager(address(poolManager)), treasury);
        StableLPFactory factory = new StableLPFactory(address(impl));
        StableLPManager.StablePoolInit[] memory cfgs = new StableLPManager.StablePoolInit[](1);
        cfgs[0] = StableLPManager.StablePoolInit({key: key, tickLower: TL, tickUpper: TU});
        mgr = StableLPManager(
            payable(factory.createManager(
                    StableLPManager.InitParams({
                        owner: owner, name: bytes32("Envelop StableLP"), descriptor: address(0), pools: cfgs
                    })
                ))
        );

        // Fund the manager with native ETH + the pair token.
        vm.deal(address(mgr), 100 ether);
        MockERC20(Currency.unwrap(token)).mint(address(mgr), 1_000e18);
    }

    /// @dev One leg, no pre-swap: add liquidity to the ETH/token pool from balances.
    function _leg(uint256 amt) internal view returns (BaseLPManager.AllocLeg[] memory legs) {
        legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: key.toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: amt, // native side
            amount1Desired: amt, // token side
            minLiquidity: 0
        });
    }

    function test_allocate_nativePair_settlesEthFromManager() public {
        assertTrue(mgr.isManagedStable(NATIVE), "native is a managed currency");
        uint256 ethBefore = address(mgr).balance;

        vm.prank(owner);
        mgr.allocate(_leg(1e18));

        assertGt(mgr.positionOf(salt).liquidity, 0, "native-pair position opened");
        assertLt(address(mgr).balance, ethBefore, "native (ETH) settled from manager balance");
    }

    function test_withdrawTo_deliversNativeToRecipient() public {
        vm.prank(owner);
        mgr.allocate(_leg(1e18));

        address recipient = address(0xBEEF);
        uint256 amount = 1e17;

        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] = BaseLPManager.WithdrawStep({salt: salt, liquidityToPull: mgr.positionOf(salt).liquidity});
        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](0);

        vm.prank(owner);
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: recipient, requestedCurrency: NATIVE, amount: amount, pulls: pulls, swaps: swaps
            })
        );

        assertEq(recipient.balance, amount, "recipient received native ETH straight from PoolManager");
    }
}
