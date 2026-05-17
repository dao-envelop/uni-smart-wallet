// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../../src/UniSmartWallet.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MockERC20} from "./Mocks.sol";

/// @notice Shared scaffolding for tests that exercise the wallet against a real
/// in-memory V4 PoolManager. Deploys a PoolManager, two MockERC20s (sorted into
/// currency0/currency1), initializes a hookless pool at tick 0, deploys the
/// wallet, and pre-funds the wallet with 1_000e18 of each token.
abstract contract V4WalletTestBase is Test {
    UniSmartWallet internal wallet;
    PoolManager internal poolManager;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal bot = address(0xB07);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    uint160 internal sqrtPriceAtTick0;

    function setUp() public virtual {
        poolManager = new PoolManager(address(this));

        MockERC20 tokenA = new MockERC20();
        MockERC20 tokenB = new MockERC20();
        (Currency a, Currency b) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        currency0 = a;
        currency1 = b;

        sqrtPriceAtTick0 = TickMath.getSqrtPriceAtTick(0);

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))
        });
        poolManager.initialize(key, sqrtPriceAtTick0);

        vm.prank(owner);
        wallet = new UniSmartWallet(IPoolManager(address(poolManager)));

        MockERC20(Currency.unwrap(currency0)).mint(address(wallet), 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(wallet), 1_000e18);
    }
}
