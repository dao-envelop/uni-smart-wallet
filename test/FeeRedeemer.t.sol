// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {FeeRedeemer} from "../src/FeeRedeemer.sol";
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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice ERC-20 path: a manager whose treasury IS the FeeRedeemer accrues protocol fees as ERC-6909;
/// the protocol owner redeems them to real ERC-20, the claim balance goes to zero, non-owners can't.
contract FeeRedeemerTest is StableLPTestBase {
    FeeRedeemer internal redeemer;
    StableLPManager internal feeMgr; // treasury == redeemer
    PoolSwapTest internal swapRouter;
    address internal protocol = address(0xF00D); // redeemer owner
    address internal trader = address(0xCAFE);
    address internal payout = address(0xDEAD);

    function setUp() public override {
        super.setUp(); // pools initialized + deeply seeded
        redeemer = new FeeRedeemer(IPoolManager(address(poolManager)), protocol);

        StableLPManager implR = new StableLPManager(IPoolManager(address(poolManager)), address(redeemer));
        StableLPFactory factoryR = new StableLPFactory(address(implR));
        feeMgr = StableLPManager(payable(factoryR.createManager(_initParams(owner))));
        MockERC20(Currency.unwrap(USDT)).mint(address(feeMgr), FUND);

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(poolKeys[0].currency0)).mint(trader, FUND);
        MockERC20(Currency.unwrap(poolKeys[0].currency1)).mint(trader, FUND);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(poolKeys[0].currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(poolKeys[0].currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap0(bool zeroForOne, int256 amt) internal {
        vm.prank(trader);
        swapRouter.swap(
            poolKeys[0],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _accrueAndClaim() internal {
        vm.prank(owner);
        feeMgr.allocate(_allocateParams(300e18));
        _swap0(true, -1e18);
        _swap0(false, -1e18);
        vm.prank(owner);
        feeMgr.claimFees(_saltFor(0));
    }

    function test_redeem_erc20_clearsClaimAndPaysOut() public {
        _accrueAndClaim();
        Currency c0 = poolKeys[0].currency0;
        Currency c1 = poolKeys[0].currency1;
        uint256 claim0 = redeemer.claimable(c0);
        uint256 claim1 = redeemer.claimable(c1);
        assertGt(claim0 + claim1, 0, "protocol fee accrued as ERC-6909");

        Currency[] memory cs = new Currency[](2);
        cs[0] = c0;
        cs[1] = c1;
        vm.prank(protocol);
        redeemer.redeem(cs, payout);

        assertEq(_bal(c0, payout), claim0, "payout received the c0 fee");
        assertEq(_bal(c1, payout), claim1, "payout received the c1 fee");
        assertEq(redeemer.claimable(c0), 0, "c0 claim cleared");
        assertEq(redeemer.claimable(c1), 0, "c1 claim cleared");
    }

    function test_redeem_onlyOwner() public {
        _accrueAndClaim();
        Currency[] memory cs = new Currency[](1);
        cs[0] = poolKeys[0].currency0;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        redeemer.redeem(cs, payout);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(FeeRedeemer.NotPoolManager.selector);
        redeemer.unlockCallback("");
    }
}

/// @notice Native path: the protocol fee on a native (ETH) pool accrues as ERC-6909 id 0; redeem
/// delivers ETH straight to the recipient.
contract FeeRedeemerNativeTest is Test {
    PoolManager internal poolManager;
    FeeRedeemer internal redeemer;
    StableLPManager internal mgr;
    PoolSwapTest internal swapRouter;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    Currency internal token;
    PoolKey internal key;
    bytes32 internal salt;

    address internal owner = address(0xA11CE);
    address internal protocol = address(0xF00D);
    address internal trader = address(0xCAFE);
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        token = Currency.wrap(address(new MockERC20()));
        key = PoolKey({currency0: NATIVE, currency1: token, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        salt = PoolId.unwrap(key.toId());

        redeemer = new FeeRedeemer(IPoolManager(address(poolManager)), protocol);
        StableLPManager impl = new StableLPManager(IPoolManager(address(poolManager)), address(redeemer));
        StableLPFactory factory = new StableLPFactory(address(impl));
        StableLPManager.StablePoolInit[] memory cfgs = new StableLPManager.StablePoolInit[](1);
        cfgs[0] = StableLPManager.StablePoolInit({key: key, tickLower: -SPACING, tickUpper: SPACING});
        mgr = StableLPManager(
            payable(factory.createManager(
                    StableLPManager.InitParams({owner: owner, name: bytes32("Envelop StableLP"), pools: cfgs})
                ))
        );

        vm.deal(address(mgr), 100 ether);
        MockERC20(Currency.unwrap(token)).mint(address(mgr), 1_000e18);

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        vm.deal(trader, 10 ether);
        MockERC20(Currency.unwrap(token)).mint(trader, 1_000e18);
        vm.prank(trader);
        MockERC20(Currency.unwrap(token)).approve(address(swapRouter), type(uint256).max);
    }

    function _leg(uint256 amt) internal view returns (BaseLPManager.AllocLeg[] memory legs) {
        legs = new BaseLPManager.AllocLeg[](1);
        legs[0] = BaseLPManager.AllocLeg({
            poolId: key.toId(),
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    function test_redeem_native_deliversEth() public {
        vm.prank(owner);
        mgr.allocate(_leg(1e18));

        // native→token swap pays the fee in native (currency0) → accrues a native-side fee.
        vm.prank(trader);
        swapRouter.swap{value: 1e16}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.prank(owner);
        mgr.claimFees(salt);

        uint256 claim = redeemer.claimable(NATIVE);
        assertGt(claim, 0, "native protocol fee accrued");

        address recipient = address(0xBEEF);
        Currency[] memory cs = new Currency[](1);
        cs[0] = NATIVE;
        vm.prank(protocol);
        redeemer.redeem(cs, recipient);

        assertEq(recipient.balance, claim, "recipient received native fee as ETH");
        assertEq(redeemer.claimable(NATIVE), 0, "native claim cleared");
    }
}
