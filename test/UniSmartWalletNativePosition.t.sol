// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MockERC20} from "./helpers/Mocks.sol";

/// @notice Native ETH support: V4 represents native as `Currency(address(0))` (always currency0), and
/// `CurrencySettler` routes the native side through `settle{value:}` / `take`. This test proves the
/// wallet can open AND close a position in an ETH/token pool — exercising native settle (open, ETH
/// paid from the wallet balance) and native take (close, ETH returned to the wallet via `receive()`).
contract UniSmartWalletNativePositionTest is Test {
    UniSmartWallet internal wallet;
    PoolManager internal poolManager;

    Currency internal constant NATIVE = Currency.wrap(address(0));
    Currency internal token; // currency1 (address(0) < any token ⇒ native is currency0)
    PoolKey internal key;

    address internal owner = address(0xA11CE);
    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        token = Currency.wrap(address(new MockERC20()));

        key = PoolKey({
            currency0: NATIVE, // address(0) sorts first
            currency1: token,
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        vm.prank(owner);
        wallet = new UniSmartWallet(IPoolManager(address(poolManager)));

        // Fund the wallet with native ETH (settle{value:} draws from its balance) and the pair token.
        vm.deal(address(wallet), 100 ether);
        MockERC20(Currency.unwrap(token)).mint(address(wallet), 1_000e18);
    }

    function _tokenBal() internal view returns (uint256) {
        return MockERC20(Currency.unwrap(token)).balanceOf(address(wallet));
    }

    function test_openPosition_nativePair_settlesEthFromWallet() public {
        bytes32 salt = bytes32(uint256(1));
        uint256 ethBefore = address(wallet).balance;
        uint256 tokenBefore = _tokenBal();

        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e18, salt, 0, type(uint128).max, type(uint128).max);

        assertEq(wallet.positionOf(salt).liquidity, 1e18, "native-pair position opened");
        assertLt(address(wallet).balance, ethBefore, "native (ETH) settled from wallet balance");
        assertLt(_tokenBal(), tokenBefore, "pair token settled from wallet balance");
    }

    function test_closePosition_nativePair_returnsEthToWallet() public {
        bytes32 salt = bytes32(uint256(2));
        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e18, salt, 0, type(uint128).max, type(uint128).max);

        uint256 ethAfterOpen = address(wallet).balance;
        uint256 tokenAfterOpen = _tokenBal();

        vm.prank(owner);
        wallet.closePosition(salt);

        assertEq(wallet.positionOf(salt).liquidity, 0, "position closed");
        // Principal comes back: native via PoolManager.take → wallet.receive(), token via take.
        assertGt(address(wallet).balance, ethAfterOpen, "native (ETH) returned to wallet");
        assertGt(_tokenBal(), tokenAfterOpen, "pair token returned to wallet");
    }

    function test_openPosition_nativePair_byOperator() public {
        address bot = address(0xB07);
        vm.prank(owner);
        wallet.setOperator(bot, true);

        bytes32 salt = bytes32(uint256(3));
        vm.prank(bot);
        wallet.openPosition(key, -SPACING, SPACING, 1e18, salt, 0, type(uint128).max, type(uint128).max);
        assertEq(wallet.positionOf(salt).liquidity, 1e18, "operator opened native-pair position");
    }
}
