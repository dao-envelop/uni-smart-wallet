// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract StableLPFactoryTest is StableLPTestBase {
    function test_factory_createManager_mintsSingletonToOwner() public view {
        assertEq(mgr.ownerOf(mgr.TOKEN_ID()), owner, "singleton minted to owner");
        assertEq(mgr.ownerNFTHolder(), owner);
        assertEq(Currency.unwrap(mgr.QUOTE()), Currency.unwrap(USDT), "quote configured");
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

    function test_initialize_weightsNotFull_reverts() public {
        StableLPManager.InitParams memory p = _initParams(owner);
        p.pools[0].weightBps = 1; // breaks the Σ == 10_000 invariant
        vm.expectRevert(abi.encodeWithSelector(StableLPManager.WeightsNotFull.selector, uint16(1 + 3333 + 3333)));
        factory.createManager(p);
    }

    function test_name_symbol_constantsOnClone() public view {
        assertEq(mgr.name(), "Envelop StableLP");
        assertEq(mgr.symbol(), "eStableLP");
    }
}
