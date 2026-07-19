// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice task_036: envelop-protocol-v2 event-model compatibility — `EnvelopV2OracleType` declared in
/// the implementation constructor (not per-clone init), and the `SmartWallet` ether-tracking events
/// (`EtherReceived` in `receive()`, `EtherBalanceChanged` around value-moving ops).
contract EnvelopEventModelTest is StableLPTestBase {
    // ────────── EnvelopV2OracleType at impl deploy (constructor) ──────────

    function test_oracleType_emittedInStableImplConstructor() public {
        vm.expectEmit(true, false, false, true); // oracleType (indexed) + contractName (data)
        emit BaseLPManager.EnvelopV2OracleType(3000, "StableLPManager");
        new StableLPManager(IPoolManager(address(poolManager)), treasury);
    }

    function test_oracleType_emittedInVolatileImplConstructor() public {
        vm.expectEmit(true, false, false, true);
        emit BaseLPManager.EnvelopV2OracleType(3001, "VolatileLPManager");
        new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
    }

    // ────────── EtherReceived in receive() ──────────

    function test_receive_emitsEtherReceived() public {
        vm.deal(address(this), 1 ether);
        vm.expectEmit(true, true, true, true, address(mgr));
        emit BaseLPManager.EtherReceived(1 ether, 1 ether, address(this)); // mgr held 0 native ⇒ balance == 1 ether
        (bool ok,) = address(mgr).call{value: 1 ether}("");
        assertTrue(ok, "native transfer accepted");
        assertEq(address(mgr).balance, 1 ether, "manager holds the ether");
    }

    // ────────── EtherBalanceChanged around a value-moving op (escape hatch) ──────────

    function test_executeEncodedTxBatch_emitsEtherBalanceChanged() public {
        vm.deal(address(mgr), 5 ether);
        address[] memory targets = new address[](1);
        targets[0] = address(0xCAFE);
        uint256[] memory values = new uint256[](1);
        values[0] = 2 ether;
        bytes[] memory datas = new bytes[](1);
        datas[0] = ""; // empty ⇒ plain native send

        // before=5, after=3, txValue=0 (owner sends no value), txSender=owner.
        vm.expectEmit(true, true, true, true, address(mgr));
        emit BaseLPManager.EtherBalanceChanged(5 ether, 3 ether, 0, owner);
        vm.prank(owner);
        mgr.executeEncodedTxBatch(targets, values, datas);
        assertEq(address(mgr).balance, 3 ether, "2 ether sent out");
    }

    /// @dev A value-moving op that does NOT touch native emits no EtherBalanceChanged (bb == ba guard).
    function test_noEtherChange_noEvent() public {
        // allocate on all-ERC20 stable pools: native balance stays 0 ⇒ no EtherBalanceChanged.
        vm.recordLogs();
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));
        // Assert no EtherBalanceChanged topic appears.
        bytes32 sig = keccak256("EtherBalanceChanged(uint256,uint256,uint256,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics.length == 0 || logs[i].topics[0] != sig, "no EtherBalanceChanged on ERC20-only op"
            );
        }
    }
}
