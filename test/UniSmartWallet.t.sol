// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";

contract UniSmartWalletMintHarness is UniSmartWallet {
    constructor(address pm) UniSmartWallet(pm) {}

    function exposedMint(address to, uint256 id) external {
        _mint(to, id);
    }

    function exposedBurn(uint256 id) external {
        _burn(id);
    }
}

contract UniSmartWalletTest is Test {
    UniSmartWallet internal wallet;
    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal bot = address(0xB07);
    address internal bot2 = address(0xB072);
    address internal poolManagerPlaceholder = address(0xCAFE);

    event OperatorSet(address indexed operator, bool allowed);

    function setUp() public {
        vm.prank(owner);
        wallet = new UniSmartWallet(poolManagerPlaceholder);
    }

    // ────────── Singleton invariant ──────────

    function test_singletonNFT_mintsToOwnerOnDeploy() public view {
        assertEq(wallet.ownerOf(wallet.TOKEN_ID()), owner);
    }

    function test_singletonNFT_cannotMintMore() public {
        vm.prank(owner);
        UniSmartWalletMintHarness h = new UniSmartWalletMintHarness(poolManagerPlaceholder);
        vm.expectRevert(UniSmartWallet.SingletonAlreadyMinted.selector);
        h.exposedMint(alice, 2);
    }

    function test_singletonNFT_cannotBurn() public {
        vm.prank(owner);
        UniSmartWalletMintHarness h = new UniSmartWalletMintHarness(poolManagerPlaceholder);
        uint256 id = h.TOKEN_ID();
        vm.expectRevert(UniSmartWallet.SingletonBurnForbidden.selector);
        h.exposedBurn(id);
    }

    // ────────── Transfer semantics ──────────

    function test_nftTransfer_handsOverControl() public {
        uint256 id = wallet.TOKEN_ID();

        vm.prank(owner);
        wallet.transferFrom(owner, alice, id);
        assertEq(wallet.ownerOf(id), alice);

        // Old owner can no longer call onlyOwnerNFT-gated functions.
        vm.prank(owner);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.setOperator(bot, true);

        // New owner can.
        vm.prank(alice);
        wallet.setOperator(bot, true);
        assertTrue(wallet.operators(bot));
    }

    function test_nftTransfer_clearsOperators() public {
        uint256 id = wallet.TOKEN_ID();

        vm.startPrank(owner);
        wallet.setOperator(bot, true);
        wallet.setOperator(bot2, true);
        assertTrue(wallet.operators(bot));
        assertTrue(wallet.operators(bot2));

        wallet.transferFrom(owner, alice, id);
        vm.stopPrank();

        assertFalse(wallet.operators(bot), "bot operator not cleared");
        assertFalse(wallet.operators(bot2), "bot2 operator not cleared");
    }

    // ────────── Operator delegation ──────────

    function test_setOperator_byOwner_succeeds() public {
        vm.expectEmit(true, false, false, true, address(wallet));
        emit OperatorSet(bot, true);
        vm.prank(owner);
        wallet.setOperator(bot, true);
        assertTrue(wallet.operators(bot));

        vm.prank(owner);
        wallet.setOperator(bot, false);
        assertFalse(wallet.operators(bot));
    }

    function test_setOperator_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.setOperator(bot, true);
    }

    function test_setOperator_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(UniSmartWallet.ZeroOperator.selector);
        wallet.setOperator(address(0), true);
    }
}
