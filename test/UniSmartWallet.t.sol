// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UniSmartWalletMintHarness is UniSmartWallet {
    constructor(address pm) UniSmartWallet(pm) {}

    function exposedMint(address to, uint256 id) external {
        _mint(to, id);
    }

    function exposedBurn(uint256 id) external {
        _burn(id);
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Echo {
    function ping(bytes calldata data) external pure returns (bytes calldata) {
        return data;
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

    // ────────── Deposits (no wallet-side function — verify the property) ──────────

    event EtherReceived(uint256 indexed balance, uint256 indexed txValue, address indexed txSender);
    event EtherBalanceChanged(
        uint256 indexed balanceBefore, uint256 indexed balanceAfter, uint256 indexed txValue, address txSender
    );

    function test_anyoneCanDepositNative() public {
        address depositor = address(0xD0E);
        vm.deal(depositor, 5 ether);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit EtherReceived(1 ether, 1 ether, depositor);

        vm.prank(depositor);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 1 ether);
    }

    function test_anyoneCanDepositERC20() public {
        MockERC20 token = new MockERC20();
        address depositor = address(0xD0E);
        token.mint(depositor, 1_000e18);

        vm.prank(depositor);
        token.transfer(address(wallet), 250e18);

        assertEq(token.balanceOf(address(wallet)), 250e18);
        assertEq(token.balanceOf(depositor), 750e18);
    }

    // ────────── Execute primitives ──────────

    function test_executeEncodedTx_withdrawNative_byOwner_succeeds() public {
        vm.deal(address(wallet), 3 ether);

        // EtherBalanceChanged from parent fixEtherBalance modifier
        vm.expectEmit(true, true, true, true, address(wallet));
        emit EtherBalanceChanged(3 ether, 2 ether, 0, owner);

        vm.prank(owner);
        wallet.executeEncodedTx(payable(alice), 1 ether, "");

        assertEq(alice.balance, 1 ether);
        assertEq(address(wallet).balance, 2 ether);
    }

    function test_executeEncodedTx_withdrawERC20_byOwner_succeeds() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 1_000e18);

        bytes memory data = abi.encodeCall(IERC20.transfer, (alice, 400e18));

        vm.prank(owner);
        wallet.executeEncodedTx(address(token), 0, data);

        assertEq(token.balanceOf(alice), 400e18);
        assertEq(token.balanceOf(address(wallet)), 600e18);
    }

    function test_executeEncodedTx_byNonOwner_reverts() public {
        vm.deal(address(wallet), 1 ether);
        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.executeEncodedTx(payable(alice), 1 ether, "");
    }

    function test_executeEncodedTx_byOperator_reverts() public {
        vm.deal(address(wallet), 1 ether);

        vm.prank(owner);
        wallet.setOperator(bot, true);

        // Operator can drive position ops (future tasks) but must NOT execute arbitrary calls.
        vm.prank(bot);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.executeEncodedTx(payable(bot), 1 ether, "");
    }

    function test_executeEncodedTx_arbitraryCall_returnsData() public {
        Echo echo = new Echo();
        bytes memory payload = abi.encodeCall(Echo.ping, (hex"deadbeef"));

        vm.prank(owner);
        bytes memory ret = wallet.executeEncodedTx(address(echo), 0, payload);

        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded, hex"deadbeef");
    }

    function test_executeEncodedTxBatch_multipleActions_succeeds() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 1_000e18);

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory datas = new bytes[](3);

        targets[0] = address(token);
        targets[1] = address(token);
        targets[2] = address(token);

        datas[0] = abi.encodeCall(IERC20.approve, (alice, 100e18));
        datas[1] = abi.encodeCall(IERC20.transfer, (alice, 200e18));
        datas[2] = abi.encodeCall(IERC20.transfer, (bot, 50e18));

        vm.prank(owner);
        wallet.executeEncodedTxBatch(targets, values, datas);

        assertEq(token.balanceOf(alice), 200e18);
        assertEq(token.balanceOf(bot), 50e18);
        assertEq(token.allowance(address(wallet), alice), 100e18);
    }

    function test_executeEncodedTxBatch_arrayMismatch_reverts() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("DifferentArraysLength(uint256,uint256)", 2, 1));
        wallet.executeEncodedTxBatch(targets, values, datas);
    }

    function test_executeEncodedTxBatch_byNonOwner_reverts() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory datas = new bytes[](0);

        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.executeEncodedTxBatch(targets, values, datas);
    }
}
