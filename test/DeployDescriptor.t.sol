// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeployDescriptor} from "../script/DeployDescriptor.s.sol";
import {DescriptorConfig} from "../script/DescriptorConfig.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

contract DeployDescriptorTest is Test {
    DeployDescriptor internal deployer;
    IPoolManager internal constant PM = IPoolManager(address(0x4444));

    function setUp() public {
        deployer = new DeployDescriptor();
    }

    function _empty() internal pure returns (DescriptorConfig.DescriptorParams memory p) {
        p.nativeSymbol = "ETH";
    }

    function test_deploy_returnsDescriptor() public {
        WalletPositionDescriptor d = deployer.deploy(PM, address(this), _empty());
        assertTrue(address(d) != address(0), "descriptor deployed");
        assertEq(d.owner(), address(this), "owner");
        assertEq(address(d.POOL_MANAGER()), address(PM), "pool manager");
        assertEq(d.nativeSymbol(), "ETH", "native symbol");
    }

    function test_deploy_distinctInstances() public {
        WalletPositionDescriptor a = deployer.deploy(PM, address(this), _empty());
        WalletPositionDescriptor b = deployer.deploy(PM, address(this), _empty());
        assertTrue(address(a) != address(b), "distinct deploys");
    }

    /// @notice Every production chain carries WETH, a native ticker, a stable allowlist and references;
    /// v4 entries parse into a hookless key and v3 entries into a pool address (task_055).
    function test_readDescriptorParams_productionChains() public view {
        uint256[4] memory chains = [uint256(1), 130, 8453, 42161];
        for (uint256 c = 0; c < chains.length; ++c) {
            DescriptorConfig.DescriptorParams memory p = deployer.readDescriptorParams(chains[c]);
            assertTrue(p.weth != address(0), "weth");
            assertEq(p.nativeSymbol, "ETH", "native symbol");
            assertGt(p.stablecoins.length, 0, "stablecoins");
            assertGt(p.refs.length, 0, "references");
            for (uint256 i = 0; i < p.refs.length; ++i) {
                bool v3 = p.refs[i].v3Pool != address(0);
                bool v4 = p.refs[i].v4Key.tickSpacing != 0;
                assertTrue(v3 != v4, "exactly one source per reference");
                assertEq(address(p.refs[i].v4Key.hooks), address(0), "hookless");
            }
        }
    }

    function test_readDescriptorParams_unknownChain_isEmpty() public view {
        DescriptorConfig.DescriptorParams memory p = deployer.readDescriptorParams(999_999);
        assertEq(p.refs.length, 0, "no refs");
        assertEq(p.stablecoins.length, 0, "no stables");
        assertEq(p.nativeSymbol, "ETH", "default ticker");
    }
}
