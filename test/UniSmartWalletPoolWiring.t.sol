// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockHookRegistry} from "./helpers/Mocks.sol";

/// @notice Tests for task #3 — PoolManager wiring, hook policy, position state + views.
/// PoolManager itself is a non-executable placeholder address; nothing here calls
/// PoolManager methods (those land in #4/#5), so the placeholder works fine.
contract UniSmartWalletPoolWiringTest is Test {
    UniSmartWallet internal wallet;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    IPoolManager internal poolManager = IPoolManager(address(0xCAFE));
    address internal hookAddr = address(0xBADC0DE);

    event HookAllowed(address indexed hook, bool allowed);
    event HookRegistrySet(address indexed registry);

    function setUp() public {
        vm.prank(owner);
        wallet = new UniSmartWallet(poolManager);
    }

    // ────────── Constructor wiring ──────────

    function test_constructor_storesPoolManager() public view {
        assertEq(address(wallet.POOL_MANAGER()), address(poolManager));
    }

    function test_constructor_seedsHookZero() public view {
        assertTrue(wallet.allowedHooks(address(0)), "address(0) hook must be seeded");
    }

    function test_constructor_hookRegistryDefaultsZero() public view {
        assertEq(wallet.hookRegistry(), address(0));
    }

    // ────────── unlockCallback gating ──────────

    function test_unlockCallback_rejectsNonPoolManager() public {
        // Caller is `this` (the test), not POOL_MANAGER → must revert.
        vm.expectRevert(UniSmartWallet.NotPoolManager.selector);
        wallet.unlockCallback(abi.encode(UniSmartWallet.Op.OPEN, bytes("")));
    }

    function test_unlockCallback_fromPoolManager_dispatchesToStub() public {
        // Spoof PoolManager as caller. Each op handler reverts NotImplemented for now;
        // this proves the dispatcher actually routes the decoded op.
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.NotImplemented.selector, UniSmartWallet.Op.OPEN));
        wallet.unlockCallback(abi.encode(UniSmartWallet.Op.OPEN, bytes("")));

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.NotImplemented.selector, UniSmartWallet.Op.CLOSE));
        wallet.unlockCallback(abi.encode(UniSmartWallet.Op.CLOSE, bytes("")));

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.NotImplemented.selector, UniSmartWallet.Op.DECREASE));
        wallet.unlockCallback(abi.encode(UniSmartWallet.Op.DECREASE, bytes("")));

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(UniSmartWallet.NotImplemented.selector, UniSmartWallet.Op.POKE));
        wallet.unlockCallback(abi.encode(UniSmartWallet.Op.POKE, bytes("")));
    }

    // ────────── Hook whitelist ──────────

    function test_setHookAllowed_byOwner_succeeds() public {
        vm.expectEmit(true, false, false, true, address(wallet));
        emit HookAllowed(hookAddr, true);

        vm.prank(owner);
        wallet.setHookAllowed(hookAddr, true);
        assertTrue(wallet.allowedHooks(hookAddr));

        vm.prank(owner);
        wallet.setHookAllowed(hookAddr, false);
        assertFalse(wallet.allowedHooks(hookAddr));
    }

    function test_setHookAllowed_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.setHookAllowed(hookAddr, true);
    }

    function test_setHookRegistry_byOwner_succeeds() public {
        MockHookRegistry reg = new MockHookRegistry(true);

        vm.expectEmit(true, false, false, true, address(wallet));
        emit HookRegistrySet(address(reg));

        vm.prank(owner);
        wallet.setHookRegistry(address(reg));
        assertEq(wallet.hookRegistry(), address(reg));
    }

    function test_setHookRegistry_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(UniSmartWallet.NotOwnerNFT.selector);
        wallet.setHookRegistry(address(0xDEAD));
    }

    // ────────── Hook policy resolution (exercised via the dispatcher, indirectly) ──────────
    // _isHookAllowed is internal; we cover its branches via a tiny harness wrapper.

    function test_hookRegistryZero_localWhitelistDecides() public {
        UniSmartWalletHookHarness h = new UniSmartWalletHookHarness(poolManager);
        // address(0) seeded
        assertTrue(h.isHookAllowed(address(0)));
        // arbitrary hook not whitelisted yet
        assertFalse(h.isHookAllowed(hookAddr));
        // owner is `this` (the harness was deployed by the test contract, so msg.sender of
        // the constructor inside Harness is the test) — explicitly use ownerOf
        address ho = h.ownerOf(h.TOKEN_ID());
        vm.prank(ho);
        h.setHookAllowed(hookAddr, true);
        assertTrue(h.isHookAllowed(hookAddr));
    }

    function test_hookRegistryConfigured_mustAlsoApprove() public {
        UniSmartWalletHookHarness h = new UniSmartWalletHookHarness(poolManager);
        address ho = h.ownerOf(h.TOKEN_ID());

        vm.startPrank(ho);
        h.setHookAllowed(hookAddr, true);
        MockHookRegistry reg = new MockHookRegistry(false); // default reject
        h.setHookRegistry(address(reg));
        vm.stopPrank();

        // Local whitelist allows, but registry rejects → overall reject.
        assertFalse(h.isHookAllowed(hookAddr));

        reg.setAllowed(hookAddr, true);
        assertTrue(h.isHookAllowed(hookAddr));
    }

    function test_hookRegistryConfigured_localWhitelistStillRequired() public {
        UniSmartWalletHookHarness h = new UniSmartWalletHookHarness(poolManager);
        address ho = h.ownerOf(h.TOKEN_ID());

        MockHookRegistry reg = new MockHookRegistry(true); // default approve
        vm.prank(ho);
        h.setHookRegistry(address(reg));

        // Registry would approve, but local whitelist doesn't list `hookAddr`.
        assertFalse(h.isHookAllowed(hookAddr));
    }

    // ────────── Position storage / views ──────────

    function test_views_empty() public view {
        assertEq(wallet.openPositionCount(), 0);
        UniSmartWallet.Position memory p = wallet.positionOf(bytes32(uint256(123)));
        assertEq(p.liquidity, 0);
        assertEq(p.openedAt, 0);
    }

    function test_ownerNFTHolder_tracksTransfer() public {
        assertEq(wallet.ownerNFTHolder(), owner);

        uint256 id = wallet.TOKEN_ID();
        vm.prank(owner);
        wallet.transferFrom(owner, alice, id);

        assertEq(wallet.ownerNFTHolder(), alice);
    }
}

/// @dev Exposes the internal `_isHookAllowed` for direct branch coverage.
contract UniSmartWalletHookHarness is UniSmartWallet {
    constructor(IPoolManager pm) UniSmartWallet(pm) {}

    function isHookAllowed(address hook) external view returns (bool) {
        return _isHookAllowed(hook);
    }
}
