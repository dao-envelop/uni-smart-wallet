// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";

contract WalletPositionDescriptorTest is V4WalletTestBase {
    WalletPositionDescriptor internal descriptor;
    PoolSwapTest internal swapRouter;
    address internal trader = address(0xCAFE);

    string internal constant JSON_PREFIX = "data:application/json;base64,";

    event MetadataUpdate(uint256 _tokenId);

    function setUp() public override {
        super.setUp();
        descriptor = new WalletPositionDescriptor();
        vm.prank(owner);
        wallet.setPositionDescriptor(address(descriptor));

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        MockERC20(Currency.unwrap(currency0)).mint(trader, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 1_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _open(bytes32 salt, int24 tl, int24 tu) internal {
        vm.prank(owner);
        wallet.openPosition(key, tl, tu, 1e18, salt, 0, type(uint128).max, type(uint128).max);
    }

    function _swap(bool zeroForOne, int256 amt) internal {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ────────── tokenURI ──────────

    function test_tokenURI_noDescriptor_returnsEmpty() public {
        UniSmartWallet bare = new UniSmartWallet(IPoolManager(address(poolManager)));
        assertEq(bytes(bare.tokenURI(1)).length, 0, "no descriptor returns empty");
    }

    function test_tokenURI_emptyPortfolio_isValidDataUri() public view {
        string memory uri = wallet.tokenURI(1);
        assertTrue(_startsWith(uri, JSON_PREFIX), "data:application/json prefix");
    }

    function test_tokenURI_withPositionsAndFees_renders() public {
        _open(bytes32(uint256(1)), -SPACING, SPACING);
        _open(bytes32(uint256(2)), -2 * SPACING, 2 * SPACING);
        _swap(true, -1e15);
        _swap(false, -1e15);

        string memory uri = wallet.tokenURI(1);
        assertTrue(_startsWith(uri, JSON_PREFIX), "prefix");
        // Two positions + SVG + attributes ⇒ a non-trivial payload.
        assertGt(bytes(uri).length, 400, "rendered payload");
    }

    function test_tokenURI_unmintedId_reverts() public {
        vm.expectRevert();
        wallet.tokenURI(2); // only TOKEN_ID = 1 exists
    }

    // ────────── descriptor setter ──────────

    function test_setPositionDescriptor_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(SingletonNFTOwned.NotOwnerNFT.selector);
        wallet.setPositionDescriptor(address(descriptor));
    }

    function test_supportsInterface_erc4906() public view {
        assertTrue(wallet.supportsInterface(0x49064906), "ERC-4906 advertised");
    }

    // ────────── ERC-4906 refresh signals ──────────

    function test_metadataUpdate_emittedOnOpen() public {
        vm.expectEmit(address(wallet));
        emit MetadataUpdate(wallet.TOKEN_ID());
        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e18, bytes32(uint256(7)), 0, type(uint128).max, type(uint128).max);
    }

    function test_metadataUpdate_emittedOnClose() public {
        _open(bytes32(uint256(8)), -SPACING, SPACING);
        vm.expectEmit(address(wallet));
        emit MetadataUpdate(wallet.TOKEN_ID());
        vm.prank(owner);
        wallet.closePosition(bytes32(uint256(8)));
    }

    // ────────── helper ──────────

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(p);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; ++i) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }
}
