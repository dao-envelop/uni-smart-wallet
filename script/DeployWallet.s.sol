// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UniSmartWallet} from "../src/UniSmartWallet.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Deploys a single UniSmartWallet. Per-chain parameters live in
/// `script/chain_params.json` keyed by chain ID — the script reads them at
/// runtime via `block.chainid` so the same invocation works on any supported
/// network without env-var plumbing.
///
/// Production use:
///   forge script script/DeployWallet.s.sol --rpc-url $RPC \
///     --sender $SENDER --account $KEYSTORE --broadcast
///
/// If `initialOwner` from the JSON entry differs from the broadcaster, the
/// script transfers the singleton NFT in the same broadcast so the wallet
/// is fully owned by `initialOwner` by the end of `run()`.
contract DeployWallet is Script {
    string internal constant DEFAULT_CONFIG_PATH = "./script/chain_params.json";

    error ChainConfigMissing(uint256 chainId, string path);
    error InvalidPoolManager(uint256 chainId);
    error InvalidInitialOwner(uint256 chainId);

    function run() external returns (UniSmartWallet wallet) {
        (IPoolManager poolManager, address initialOwner) = loadConfig(DEFAULT_CONFIG_PATH, block.chainid);

        vm.startBroadcast();
        wallet = deployAndAssign(poolManager, initialOwner);
        vm.stopBroadcast();

        console2.log("Chain ID:      ", block.chainid);
        console2.log("UniSmartWallet:", address(wallet));
        console2.log("PoolManager:   ", address(poolManager));
        console2.log("NFT holder:    ", wallet.ownerOf(wallet.TOKEN_ID()));
    }

    /// @notice Read `(poolManager, initialOwner)` for the given chain from a JSON file.
    function loadConfig(string memory path, uint256 chainId)
        public
        view
        returns (IPoolManager poolManager, address initialOwner)
    {
        string memory json;
        try vm.readFile(path) returns (string memory contents) {
            json = contents;
        } catch {
            revert ChainConfigMissing(chainId, path);
        }
        return parseConfig(json, chainId, path);
    }

    /// @notice Parse a chain-params JSON string. Split out from `loadConfig` so tests can
    /// drive the parser with inline strings (sidesteps fs_permissions / filesystem flakiness).
    /// Reverts on missing entry or zero-address fields — both indicate a misconfigured deploy.
    function parseConfig(string memory json, uint256 chainId, string memory sourceLabel)
        public
        view
        returns (IPoolManager poolManager, address initialOwner)
    {
        // jq-style path: `.["<chainId>"].field`. The bracket form sidesteps the
        // issue that pure-digit keys aren't valid identifiers for the dot form.
        string memory base = string.concat('.["', vm.toString(chainId), '"]');
        string memory pmPath = string.concat(base, ".poolManager");
        string memory ioPath = string.concat(base, ".initialOwner");

        if (!vm.keyExistsJson(json, pmPath) || !vm.keyExistsJson(json, ioPath)) {
            revert ChainConfigMissing(chainId, sourceLabel);
        }

        address pm = vm.parseJsonAddress(json, pmPath);
        address io = vm.parseJsonAddress(json, ioPath);

        if (pm == address(0)) revert InvalidPoolManager(chainId);
        if (io == address(0)) revert InvalidInitialOwner(chainId);

        poolManager = IPoolManager(pm);
        initialOwner = io;
    }

    /// @notice Deploy + (if needed) transfer the singleton NFT to `initialOwner`.
    /// Public so tests can exercise the deploy logic directly. Reads the current
    /// NFT holder from the wallet — under vm.broadcast that's the broadcaster,
    /// which is also the msg.sender for the subsequent transferFrom (so the
    /// ERC-721 ownership check passes).
    function deployAndAssign(IPoolManager poolManager, address initialOwner) public returns (UniSmartWallet wallet) {
        wallet = new UniSmartWallet(poolManager);
        address currentHolder = wallet.ownerOf(wallet.TOKEN_ID());
        if (currentHolder != initialOwner) {
            wallet.transferFrom(currentHolder, initialOwner, wallet.TOKEN_ID());
        }
    }
}
