// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Universal {LPManagerFactory}: clones+inits any allowlisted BaseLPManager product from raw
/// init calldata. The inherited {StableLPTestBase} builds a factory (owned by this test) allowlisting
/// the Stable impl and clones `mgr` (owner nonce 0) in setUp.
contract LPManagerFactoryTest is StableLPTestBase {
    // ────────── clone + init round-trip (Stable) ──────────

    function test_factory_createManager_mintsSingletonToOwner() public view {
        assertEq(mgr.ownerOf(mgr.TOKEN_ID()), owner, "singleton minted to owner");
        assertTrue(mgr.isManagedStable(USDT), "USDT managed");
        assertTrue(mgr.isManagedStable(USDC) && mgr.isManagedStable(DAI) && mgr.isManagedStable(USDe));
    }

    function test_factory_predictAddress_matchesDeployed() public {
        // owner already consumed nonce 0 in setUp; predict the next manager (nonce 1). The salt binds
        // keccak256(initData), so predict must use the SAME calldata the deployment will use.
        bytes memory initData = abi.encodeCall(StableLPManager.initialize, (_initParams(owner)));
        address predicted = factory.predictManagerAddress(address(impl), owner, 1, initData);
        address deployed = address(FactoryHelper.cloneStable(factory, address(impl), _initParams(owner)));
        assertEq(deployed, predicted, "deterministic address matches");
    }

    // ────────── universal: a second product through the SAME factory ──────────

    function test_factory_createsVolatileManager() public {
        VolatileLPManager volImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        factory.setImplementation(address(volImpl), true);

        VolatileLPManager m = FactoryHelper.cloneVolatile(factory, address(volImpl), _volatileParams(owner));
        assertEq(m.ownerOf(m.TOKEN_ID()), owner, "volatile singleton minted to owner");
        assertEq(m.symbol(), "eVolLP", "volatile symbol");
        assertTrue(m.isManagedStable(poolKeys[0].currency0) && m.isManagedStable(poolKeys[0].currency1));
    }

    function test_factory_sameNonce_differentImpl_distinctAddresses() public {
        VolatileLPManager volImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        // impl is embedded in the EIP-1167 initcode ⇒ same (owner,nonce,initData), different impl ⇒ different address.
        bytes memory initData = abi.encodeCall(StableLPManager.initialize, (_initParams(owner)));
        address a = factory.predictManagerAddress(address(impl), owner, 7, initData);
        address b = factory.predictManagerAddress(address(volImpl), owner, 7, initData);
        assertTrue(a != b, "stable and volatile clones never collide");
    }

    // ────────── allowlist gating ──────────

    function test_createManager_unlistedImpl_reverts() public {
        StableLPManager rogue = new StableLPManager(IPoolManager(address(poolManager)), treasury);
        bytes memory initData = abi.encodeCall(StableLPManager.initialize, (_initParams(owner)));
        vm.expectRevert(abi.encodeWithSelector(LPManagerFactory.NotImplementation.selector, address(rogue)));
        factory.createManager(address(rogue), owner, initData);
    }

    function test_setImplementation_onlyOwner() public {
        vm.prank(bot);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bot));
        factory.setImplementation(address(0xBEEF), true);
    }

    function test_setImplementation_addThenRevoke() public {
        VolatileLPManager volImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        bytes memory initData = abi.encodeCall(VolatileLPManager.initialize, (_volatileParams(owner)));

        factory.setImplementation(address(volImpl), true);
        assertTrue(factory.isImplementation(address(volImpl)), "blessed");
        factory.createManager(address(volImpl), owner, initData); // works

        factory.setImplementation(address(volImpl), false);
        assertFalse(factory.isImplementation(address(volImpl)), "revoked");
        vm.expectRevert(abi.encodeWithSelector(LPManagerFactory.NotImplementation.selector, address(volImpl)));
        factory.createManager(address(volImpl), owner, initData);
    }

    // ────────── init-guard reverts ──────────

    function test_createManager_ownerMismatch_reverts() public {
        // initData initializes the clone to `bot`, but the factory caller asserts `owner`.
        StableLPManager.InitParams memory p = _initParams(bot);
        bytes memory initData = abi.encodeCall(StableLPManager.initialize, (p));
        vm.expectRevert(abi.encodeWithSelector(LPManagerFactory.OwnerMismatch.selector, owner, bot));
        factory.createManager(address(impl), owner, initData);
    }

    function test_createManager_initFailed_reverts() public {
        // A selector the manager doesn't implement ⇒ the low-level call reverts ⇒ InitFailed.
        vm.expectRevert(LPManagerFactory.InitFailed.selector);
        factory.createManager(address(impl), owner, abi.encodeWithSelector(bytes4(0xdeadbeef)));
    }

    function test_createManager_zeroOwner_reverts() public {
        bytes memory initData = abi.encodeCall(StableLPManager.initialize, (_initParams(owner)));
        vm.expectRevert(LPManagerFactory.ZeroOwner.selector);
        factory.createManager(address(impl), address(0), initData);
    }

    function test_nonce_incrementsPerOwner() public {
        uint256 before = factory.nonce(owner);
        FactoryHelper.cloneStable(factory, address(impl), _initParams(owner));
        assertEq(factory.nonce(owner), before + 1, "owner nonce advanced");
    }

    // ────────── init passthrough (name / pools / descriptor) still works via the factory ──────────

    function test_initialize_isOneShot_reverts() public {
        vm.expectRevert(BaseLPManager.AlreadyInitialized.selector);
        mgr.initialize(_initParams(owner));
    }

    function test_initialize_noPools_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        p.pools = new StableLPManager.StablePoolInit[](0);
        vm.expectRevert(BaseLPManager.NoPools.selector);
        FactoryHelper.cloneStable(factory, address(impl), p);
    }

    function test_initialize_tooManyPools_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        uint256 n = uint256(mgr.MAX_POOLS()) + 1;
        StableLPManager.StablePoolInit[] memory many = new StableLPManager.StablePoolInit[](n);
        for (uint256 i = 0; i < n; ++i) {
            many[i] = StableLPManager.StablePoolInit({key: poolKeys[0], tickLower: TL, tickUpper: TU});
        }
        p.pools = many;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.TooManyPools.selector, n));
        FactoryHelper.cloneStable(factory, address(impl), p);
    }

    function test_initialize_duplicatePool_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        StableLPManager.StablePoolInit[] memory dup = new StableLPManager.StablePoolInit[](2);
        dup[0] = StableLPManager.StablePoolInit({key: poolKeys[0], tickLower: TL, tickUpper: TU});
        dup[1] = StableLPManager.StablePoolInit({key: poolKeys[0], tickLower: TL, tickUpper: TU}); // same poolId
        p.pools = dup;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.DuplicatePool.selector, poolKeys[0].toId()));
        FactoryHelper.cloneStable(factory, address(impl), p);
    }

    function test_name_defaultAndSymbolOnClone() public view {
        assertEq(mgr.name(), "Envelop StableLP");
        assertEq(mgr.symbol(), "eStableLP");
    }

    function test_name_customPerClone() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        p.name = bytes32("Acme USD Vault");
        StableLPManager m = FactoryHelper.cloneStable(factory, address(impl), p);
        assertEq(m.name(), "Acme USD Vault", "custom name round-trips");
        assertEq(m.symbol(), "eStableLP", "symbol unchanged");
    }

    function test_name_maxLength31() public {
        string memory max31 = "Envelop StableLP Vault v2 Alpha"; // 31 chars
        assertEq(bytes(max31).length, 31, "fixture is 31 bytes");
        StableLPManager.InitParams memory p = _initParams(owner);
        p.name = bytes32(bytes(max31));
        StableLPManager m = FactoryHelper.cloneStable(factory, address(impl), p);
        assertEq(m.name(), max31, "31-char name round-trips");
    }

    function test_name_emptyFallsBackToDefault() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        p.name = bytes32(0);
        StableLPManager m = FactoryHelper.cloneStable(factory, address(impl), p);
        assertEq(m.name(), "Envelop LP Uniswap Manager", "empty packed name falls back to the default");
        assertEq(m.symbol(), "eStableLP", "symbol unchanged");
    }

    function test_initialize_setsDefaultDescriptor() public {
        address descriptor = address(0xDE5C);
        StableLPManager.InitParams memory p = _initParams(owner);
        p.descriptor = descriptor;
        StableLPManager m = FactoryHelper.cloneStable(factory, address(impl), p);
        assertEq(m.positionDescriptor(), descriptor, "descriptor wired at init");
    }

    function test_initialize_zeroDescriptor_leavesUnset() public view {
        assertEq(mgr.positionDescriptor(), address(0), "no descriptor when zero at init");
    }

    // ────────── helpers ──────────

    function _volatileParams(address owner_) internal view returns (VolatileLPManager.InitParams memory p) {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = poolKeys[0];
        p = VolatileLPManager.InitParams({owner: owner_, name: bytes32("Vol"), descriptor: address(0), pools: pools});
    }
}
