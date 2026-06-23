// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Tests for task #3 — PoolManager wiring, position state + views.
/// PoolManager itself is a non-executable placeholder address; nothing here calls
/// PoolManager methods (those land in #4/#5), so the placeholder works fine.
contract UniSmartWalletPoolWiringTest is Test {
    UniSmartWallet internal wallet;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    IPoolManager internal poolManager = IPoolManager(address(0xCAFE));

    function setUp() public {
        vm.prank(owner);
        wallet = new UniSmartWallet(poolManager);
    }

    // ────────── Constructor wiring ──────────

    function test_constructor_storesPoolManager() public view {
        assertEq(address(wallet.POOL_MANAGER()), address(poolManager));
    }

    // ────────── unlockCallback gating ──────────

    function test_unlockCallback_rejectsNonPoolManager() public {
        // Caller is `this` (the test), not POOL_MANAGER → must revert.
        vm.expectRevert(V4PositionManager.NotPoolManager.selector);
        wallet.unlockCallback(abi.encode(V4PositionManager.Op.OPEN, bytes("")));
    }

    // Dispatcher-routing test removed: after #4/#5 all four op handlers are real
    // (no NotImplemented stubs left). End-to-end dispatch is now covered by the
    // openPosition / closePosition / decreasePosition / pokePosition test suites.

    // ────────── Position storage / views ──────────

    function test_views_empty() public view {
        assertEq(wallet.openPositionCount(), 0);
        V4PositionManager.Position memory p = wallet.positionOf(bytes32(uint256(123)));
        assertEq(p.liquidity, 0);
        assertEq(p.openedAt, 0);
    }

    function test_ownerNFTHolder_tracksTransfer() public {
        assertEq(wallet.ownerOf(wallet.TOKEN_ID()), owner);

        uint256 id = wallet.TOKEN_ID();
        vm.prank(owner);
        wallet.transferFrom(owner, alice, id);

        assertEq(wallet.ownerOf(wallet.TOKEN_ID()), alice);
    }
}
