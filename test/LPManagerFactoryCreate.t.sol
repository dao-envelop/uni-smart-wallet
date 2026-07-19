// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";

/// @notice task_033: LPManagerFactory hardening — L-FAC-1 (initData bound into the CREATE2 salt), the
/// non-deterministic create path, and native-value forwarding on creation.
contract LPManagerFactoryCreateTest is StableLPTestBase {
    address internal alice = address(0xA11);
    address internal attacker = address(0xBAD);

    function _init(address owner_) internal view returns (bytes memory) {
        return abi.encodeCall(StableLPManager.initialize, (_initParams(owner_)));
    }

    function _initNamed(address owner_, bytes32 name) internal view returns (bytes memory) {
        StableLPManager.InitParams memory p = _initParams(owner_);
        p.name = name;
        return abi.encodeCall(StableLPManager.initialize, (p));
    }

    // ────────── L-FAC-1: salt binds initData ──────────

    function test_differentInitData_yieldsDifferentAddress() public view {
        uint256 n = factory.nonce(alice);
        address a = factory.predictManagerAddress(address(impl), alice, n, _initNamed(alice, bytes32("A")));
        address b = factory.predictManagerAddress(address(impl), alice, n, _initNamed(alice, bytes32("B")));
        assertTrue(a != b, "substituted initData must change the predicted address");
    }

    function test_frontRunSubstitution_cannotOccupyPredictedAddress() public {
        // Victim `alice` predicts (and would pre-fund) her address for HER config at her current nonce.
        uint256 n = factory.nonce(alice);
        bytes memory victimInit = _initNamed(alice, bytes32("Alice Vault"));
        address predicted = factory.predictManagerAddress(address(impl), alice, n, victimInit);

        // Attacker front-runs createManager for the same owner/nonce but a DIFFERENT config.
        bytes memory attackerInit = _initNamed(alice, bytes32("Attacker Cfg"));
        vm.prank(attacker);
        address deployed = factory.createManager(address(impl), alice, attackerInit);

        // The substituted config lands at a different address; the victim's pre-funded address is untouched.
        assertTrue(deployed != predicted, "attacker cannot deploy a different config at the predicted address");
    }

    function test_predict_matchesActualDeploy_withInitData() public {
        uint256 n = factory.nonce(alice);
        bytes memory initData = _init(alice);
        address predicted = factory.predictManagerAddress(address(impl), alice, n, initData);
        address deployed = factory.createManager(address(impl), alice, initData);
        assertEq(deployed, predicted, "deploy matches the initData-bound prediction");
    }

    // ────────── non-deterministic create ──────────

    function test_nondeterministic_mintsToOwner_distinctAddress() public {
        uint256 n = factory.nonce(alice);
        address det = factory.predictManagerAddress(address(impl), alice, n, _init(alice));
        address m = factory.createManagerNondeterministic(address(impl), alice, _init(alice));
        assertEq(StableLPManager(payable(m)).ownerOf(1), alice, "singleton minted to owner");
        assertTrue(m != det, "non-deterministic address differs from the deterministic one");
    }

    function test_nondeterministic_doesNotConsumeNonce() public {
        uint256 before = factory.nonce(alice);
        factory.createManagerNondeterministic(address(impl), alice, _init(alice));
        assertEq(factory.nonce(alice), before, "non-deterministic create leaves the nonce untouched");
    }

    function test_nondeterministic_ownerMismatch_reverts() public {
        // initData mints to `alice`, but the caller asserts `attacker`.
        vm.expectRevert(abi.encodeWithSelector(LPManagerFactory.OwnerMismatch.selector, attacker, alice));
        factory.createManagerNondeterministic(address(impl), attacker, _init(alice));
    }

    // ────────── native forwarding ──────────

    function test_native_forwarded_createManager() public {
        vm.deal(address(this), 5 ether);
        address m = factory.createManager{value: 2 ether}(address(impl), alice, _init(alice));
        assertEq(m.balance, 2 ether, "value forwarded to the deterministic manager");
    }

    function test_native_forwarded_nondeterministic() public {
        vm.deal(address(this), 5 ether);
        address m = factory.createManagerNondeterministic{value: 3 ether}(address(impl), alice, _init(alice));
        assertEq(m.balance, 3 ether, "value forwarded to the non-deterministic manager");
    }

    function test_native_zeroValue_noForward() public {
        address m = factory.createManager(address(impl), alice, _init(alice));
        assertEq(m.balance, 0, "no value => nothing forwarded");
    }

    function test_native_revertingInit_returnsEth_noStrand() public {
        vm.deal(address(this), 5 ether);
        uint256 before = address(this).balance;
        // Bad selector => init call reverts => whole creation reverts => the sent ETH is returned atomically.
        vm.expectRevert(LPManagerFactory.InitFailed.selector);
        factory.createManager{value: 1 ether}(address(impl), alice, abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertEq(address(this).balance, before, "ETH not stranded on a reverted creation");
    }

    receive() external payable {}
}
