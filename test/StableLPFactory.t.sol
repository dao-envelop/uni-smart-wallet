// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract StableLPFactoryTest is StableLPTestBase {
    function test_factory_createManager_mintsSingletonToOwner() public view {
        assertEq(mgr.ownerOf(mgr.TOKEN_ID()), owner, "singleton minted to owner");
        assertEq(mgr.ownerNFTHolder(), owner);
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
        vm.expectRevert(StableLPManager.AlreadyInitialized.selector);
        mgr.initialize(_initParams(owner));
    }

    function test_initialize_noPools_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        p.pools = new StableLPManager.PoolConfig[](0);
        vm.expectRevert(StableLPManager.NoPools.selector);
        factory.createManager(p);
    }

    function test_initialize_tooManyPools_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        uint256 n = uint256(mgr.MAX_POOLS()) + 1;
        StableLPManager.PoolConfig[] memory many = new StableLPManager.PoolConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            many[i] = StableLPManager.PoolConfig({key: poolKeys[0], tickLower: TL, tickUpper: TU});
        }
        p.pools = many;
        vm.expectRevert(abi.encodeWithSelector(StableLPManager.TooManyPools.selector, n));
        factory.createManager(p);
    }

    function test_initialize_duplicatePool_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        StableLPManager.PoolConfig[] memory dup = new StableLPManager.PoolConfig[](2);
        dup[0] = StableLPManager.PoolConfig({key: poolKeys[0], tickLower: TL, tickUpper: TU});
        dup[1] = StableLPManager.PoolConfig({key: poolKeys[0], tickLower: TL, tickUpper: TU}); // same poolId
        p.pools = dup;
        vm.expectRevert(abi.encodeWithSelector(StableLPManager.DuplicatePool.selector, poolKeys[0].toId()));
        factory.createManager(p);
    }

    function test_name_symbol_constantsOnClone() public view {
        assertEq(mgr.name(), "Envelop StableLP");
        assertEq(mgr.symbol(), "eStableLP");
    }
}
