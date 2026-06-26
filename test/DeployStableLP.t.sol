// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DeployStableLP} from "../script/DeployStableLP.s.sol";
import {CreateManager} from "../script/CreateManager.s.sol";
import {StableLPManager} from "../src/StableLPManager.sol";

/// Exposes CreateManager's internal config parser for assertions.
contract CreateManagerHarness is CreateManager {
    function parse(string memory json) external pure returns (StableLPManager.InitParams memory) {
        return _parseConfig(json);
    }
}

contract DeployStableLPTest is Test {
    DeployStableLP internal deployer;
    IPoolManager internal pm = IPoolManager(address(0xBEEF)); // not called by constructors
    address internal admin = makeAddr("admin");

    function setUp() public {
        deployer = new DeployStableLP();
    }

    function test_deploy_wiresStackTogether() public {
        DeployStableLP.Deployment memory d = deployer.deploy(pm, admin);

        // FeeRedeemer is the treasury, owned by admin, pointing at the PoolManager.
        assertEq(d.feeRedeemer.owner(), admin, "feeRedeemer owner");
        assertEq(address(d.feeRedeemer.POOL_MANAGER()), address(pm), "feeRedeemer pm");

        // Implementation taxes fees to the FeeRedeemer and shares the PoolManager.
        assertEq(d.impl.PROTOCOL_TREASURY(), address(d.feeRedeemer), "impl treasury == feeRedeemer");
        assertEq(address(d.impl.POOL_MANAGER()), address(pm), "impl pm");

        // Factory clones the implementation.
        assertEq(d.factory.implementation(), address(d.impl), "factory impl");

        assertTrue(address(d.lens) != address(0), "lens");
        assertTrue(address(d.descriptor) != address(0), "descriptor");
    }

    function test_deploy_zeroAdminStillDeploys() public {
        // deploy() takes admin already resolved; just sanity that distinct instances are produced.
        DeployStableLP.Deployment memory a = deployer.deploy(pm, admin);
        DeployStableLP.Deployment memory b = deployer.deploy(pm, admin);
        assertTrue(address(a.factory) != address(b.factory), "distinct deploys");
    }

    function test_parseConfig_parallelArrays() public {
        CreateManagerHarness h = new CreateManagerHarness();
        string memory json = string(
            abi.encodePacked(
                '{"owner":"0x00000000000000000000000000000000000000aa",',
                '"currency0":["0x0000000000000000000000000000000000000010","0x0000000000000000000000000000000000000030"],',
                '"currency1":["0x0000000000000000000000000000000000000020","0x0000000000000000000000000000000000000040"],',
                '"fee":[500,100],',
                '"tickSpacing":[10,1],',
                '"hooks":["0x0000000000000000000000000000000000000000","0x0000000000000000000000000000000000000000"],',
                '"tickLower":[-100,-5],',
                '"tickUpper":[100,5]}'
            )
        );

        StableLPManager.InitParams memory p = h.parse(json);
        assertEq(p.owner, address(0xAA), "owner");
        assertEq(p.pools.length, 2, "pool count");

        assertEq(Currency.unwrap(p.pools[0].key.currency0), address(0x10), "c0[0]");
        assertEq(Currency.unwrap(p.pools[0].key.currency1), address(0x20), "c1[0]");
        assertEq(p.pools[0].key.fee, 500, "fee[0]");
        assertEq(p.pools[0].key.tickSpacing, int24(10), "spacing[0]");
        assertEq(address(p.pools[0].key.hooks), address(0), "hooks[0]");
        assertEq(p.pools[0].tickLower, int24(-100), "lower[0]");
        assertEq(p.pools[0].tickUpper, int24(100), "upper[0]");

        assertEq(p.pools[1].key.fee, 100, "fee[1]");
        assertEq(p.pools[1].tickLower, int24(-5), "lower[1]");
    }

    function test_parseConfig_lengthMismatchReverts() public {
        CreateManagerHarness h = new CreateManagerHarness();
        string memory json = string(
            abi.encodePacked(
                '{"owner":"0x00000000000000000000000000000000000000aa",',
                '"currency0":["0x0000000000000000000000000000000000000010"],',
                '"currency1":["0x0000000000000000000000000000000000000020"],',
                '"fee":[500],',
                '"tickSpacing":[10],',
                '"hooks":["0x0000000000000000000000000000000000000000"],',
                '"tickLower":[-100],',
                '"tickUpper":[100,200]}' // mismatched length
            )
        );
        vm.expectRevert(CreateManager.LengthMismatch.selector);
        h.parse(json);
    }
}
