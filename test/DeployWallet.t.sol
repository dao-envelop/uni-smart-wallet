// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployWallet} from "../script/DeployWallet.s.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployWalletTest is Test {
    DeployWallet internal script;
    PoolManager internal poolManager;

    string internal constant FIXTURE_PATH = "./test/fixtures/chain_params.test.json";

    function setUp() public {
        script = new DeployWallet();
        poolManager = new PoolManager(address(this));
    }

    // ────────── deployAndAssign ──────────

    function test_deployAndAssign_sameOwner_skipsTransfer() public {
        UniSmartWallet w = script.deployAndAssign(IPoolManager(address(poolManager)), address(script));
        assertEq(w.ownerOf(w.TOKEN_ID()), address(script));
        assertEq(address(w.POOL_MANAGER()), address(poolManager));
    }

    function test_deployAndAssign_differentOwner_transfersNFT() public {
        address initialOwner = address(0xBEEF);
        UniSmartWallet w = script.deployAndAssign(IPoolManager(address(poolManager)), initialOwner);
        assertEq(w.ownerOf(w.TOKEN_ID()), initialOwner);
    }

    // ────────── parseConfig (inline JSON — pure parser branch coverage) ──────────

    function test_parseConfig_validEntry() public view {
        string memory json = string.concat(
            '{"31337":{"poolManager":"',
            vm.toString(address(0xAAAA)),
            '","initialOwner":"',
            vm.toString(address(0xBEEF)),
            '"}}'
        );
        (IPoolManager pm, address owner) = script.parseConfig(json, 31337, "<inline>");
        assertEq(address(pm), address(0xAAAA));
        assertEq(owner, address(0xBEEF));
    }

    function test_parseConfig_revertsOnMissingChain() public {
        string memory json =
            '{"31337":{"poolManager":"0x000000000000000000000000000000000000aaaa","initialOwner":"0x000000000000000000000000000000000000beef"}}';

        vm.expectRevert(abi.encodeWithSelector(DeployWallet.ChainConfigMissing.selector, uint256(999), "<inline>"));
        script.parseConfig(json, 999, "<inline>");
    }

    function test_parseConfig_revertsOnZeroPoolManager() public {
        string memory json =
            '{"31337":{"poolManager":"0x0000000000000000000000000000000000000000","initialOwner":"0x000000000000000000000000000000000000beef"}}';

        vm.expectRevert(abi.encodeWithSelector(DeployWallet.InvalidPoolManager.selector, uint256(31337)));
        script.parseConfig(json, 31337, "<inline>");
    }

    function test_parseConfig_revertsOnZeroInitialOwner() public {
        string memory json =
            '{"31337":{"poolManager":"0x000000000000000000000000000000000000aaaa","initialOwner":"0x0000000000000000000000000000000000000000"}}';

        vm.expectRevert(abi.encodeWithSelector(DeployWallet.InvalidInitialOwner.selector, uint256(31337)));
        script.parseConfig(json, 31337, "<inline>");
    }

    // ────────── loadConfig (full file read via committed fixture) ──────────

    function test_loadConfig_readsFixture() public view {
        (IPoolManager pm, address owner) = script.loadConfig(FIXTURE_PATH, 31337);
        assertEq(address(pm), address(0xAAAA));
        assertEq(owner, address(0xBEEF));
    }

    function test_loadConfig_revertsOnUnknownChain() public {
        vm.expectRevert(abi.encodeWithSelector(DeployWallet.ChainConfigMissing.selector, uint256(99999), FIXTURE_PATH));
        script.loadConfig(FIXTURE_PATH, 99999);
    }

    function test_loadConfig_revertsOnMissingFile() public {
        string memory missing = "./test/fixtures/does_not_exist.json";
        vm.expectRevert(abi.encodeWithSelector(DeployWallet.ChainConfigMissing.selector, uint256(1), missing));
        script.loadConfig(missing, 1);
    }
}
