// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployDescriptor} from "../script/DeployDescriptor.s.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

contract DeployDescriptorTest is Test {
    DeployDescriptor internal deployer;

    function setUp() public {
        deployer = new DeployDescriptor();
    }

    function test_deploy_returnsDescriptor() public {
        WalletPositionDescriptor d = deployer.deploy();
        assertTrue(address(d) != address(0), "descriptor deployed");
    }

    function test_deploy_distinctInstances() public {
        WalletPositionDescriptor a = deployer.deploy();
        WalletPositionDescriptor b = deployer.deploy();
        assertTrue(address(a) != address(b), "distinct deploys");
    }
}
