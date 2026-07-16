// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract StableLPFactoryTest is StableLPTestBase {
    function test_factory_createManager_mintsSingletonToOwner() public view {
        assertEq(mgr.ownerOf(mgr.TOKEN_ID()), owner, "singleton minted to owner");
        // managed stables = union of all pool currencies (USDT hub + the 3 pair sides here).
        assertTrue(mgr.isManagedStable(USDT), "USDT managed");
        assertTrue(mgr.isManagedStable(USDC) && mgr.isManagedStable(DAI) && mgr.isManagedStable(USDe));
    }

    function test_factory_predictAddress_matchesDeployed() public {
        // owner already consumed nonce 0 in setUp; predict the next manager (nonce 1).
        address predicted = factory.predictManagerAddress(owner, 1);
        address deployed = factory.createManager(_initParams(owner));
        assertEq(deployed, predicted, "deterministic address matches");
    }

    function test_initialize_isOneShot_reverts() public {
        vm.expectRevert(BaseLPManager.AlreadyInitialized.selector);
        mgr.initialize(_initParams(owner));
    }

    function test_initialize_noPools_reverts() public {
        BaseLPManager.InitParams memory p = _initParams(owner);
        p.pools = new BaseLPManager.PoolConfig[](0);
        vm.expectRevert(BaseLPManager.NoPools.selector);
        factory.createManager(p);
    }

    function test_initialize_tooManyPools_reverts() public {
        BaseLPManager.InitParams memory p = _initParams(owner);
        uint256 n = uint256(mgr.MAX_POOLS()) + 1;
        BaseLPManager.PoolConfig[] memory many = new BaseLPManager.PoolConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            many[i] = BaseLPManager.PoolConfig({key: poolKeys[0], tickLower: TL, tickUpper: TU});
        }
        p.pools = many;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.TooManyPools.selector, n));
        factory.createManager(p);
    }

    function test_initialize_duplicatePool_reverts() public {
        BaseLPManager.InitParams memory p = _initParams(owner);
        BaseLPManager.PoolConfig[] memory dup = new BaseLPManager.PoolConfig[](2);
        dup[0] = BaseLPManager.PoolConfig({key: poolKeys[0], tickLower: TL, tickUpper: TU});
        dup[1] = BaseLPManager.PoolConfig({key: poolKeys[0], tickLower: TL, tickUpper: TU}); // same poolId
        p.pools = dup;
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.DuplicatePool.selector, poolKeys[0].toId()));
        factory.createManager(p);
    }

    function test_name_defaultAndSymbolOnClone() public view {
        // setUp's _initParams names the clone "Envelop StableLP"; symbol is a shared constant.
        assertEq(mgr.name(), "Envelop StableLP");
        assertEq(mgr.symbol(), "eStableLP");
    }

    function test_name_customPerClone() public {
        BaseLPManager.InitParams memory p = _initParams(owner);
        p.name = bytes32("Acme USD Vault");
        StableLPManager m = StableLPManager(payable(factory.createManager(p)));
        assertEq(m.name(), "Acme USD Vault", "custom name round-trips");
        assertEq(m.symbol(), "eStableLP", "symbol unchanged");
    }

    function test_name_maxLength31() public {
        string memory max31 = "Envelop StableLP Vault v2 Alpha"; // 31 chars
        assertEq(bytes(max31).length, 31, "fixture is 31 bytes");
        BaseLPManager.InitParams memory p = _initParams(owner);
        p.name = bytes32(bytes(max31));
        StableLPManager m = StableLPManager(payable(factory.createManager(p)));
        assertEq(m.name(), max31, "31-char name round-trips");
    }

    function test_name_emptyFallsBackToDefault() public {
        BaseLPManager.InitParams memory p = _initParams(owner);
        p.name = bytes32(0);
        StableLPManager m = StableLPManager(payable(factory.createManager(p)));
        assertEq(m.name(), "Envelop LP Uniswap Manager", "empty packed name falls back to the default");
        assertEq(m.symbol(), "eStableLP", "symbol unchanged");
    }
}
