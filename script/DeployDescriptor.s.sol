// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

/// @notice Deploys a standalone {WalletPositionDescriptor} — the shared on-chain `tokenURI`
/// renderer used by the NFT-owned LP managers (`StableLPManager`, `VolatileLPManager`).
///
/// Use this to ship a new descriptor without re-running the whole StableLP stack
/// (`DeployStableLP.s.sol`), which would also redeploy the factory/impl/treasury and orphan
/// existing clones. The per-chain stablecoin `$1` allowlist is read from `chain_params.json`
/// (`.["<chainId>"].stablecoins`) — the same list `DeployStableLP` uses. The new address is
/// recorded into `deployments/<chainId>.json` (`.descriptor`); afterwards wire it into each
/// wallet/manager with the `cast send … setPositionDescriptor` command from `script/README.md`
/// (the NFT owner must sign that call).
///
///   forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url $RPC \
///     --account $KEYSTORE --sender $SENDER --broadcast --verify
contract DeployDescriptor is Script {
    string internal constant CONFIG_PATH = "./script/chain_params.json";

    function run() external returns (WalletPositionDescriptor descriptor) {
        address[] memory stablecoins = _readStablecoins(block.chainid);

        vm.startBroadcast();
        descriptor = deploy(stablecoins);
        vm.stopBroadcast();

        console2.log("Chain ID:   ", block.chainid);
        console2.log("Descriptor: ", address(descriptor));
        console2.log("Stablecoins:", stablecoins.length);

        _record(address(descriptor));
    }

    /// @notice Deploy the descriptor with the given `$1` stablecoin allowlist. Public + side-effect-free
    /// so tests can drive it without broadcasting or touching the filesystem.
    function deploy(address[] memory stablecoins) public returns (WalletPositionDescriptor) {
        return new WalletPositionDescriptor(stablecoins);
    }

    /// @dev Read `.["<chainId>"].stablecoins` from `chain_params.json`; missing ⇒ empty allowlist.
    function _readStablecoins(uint256 chainId) internal view returns (address[] memory) {
        if (!vm.exists(CONFIG_PATH)) return new address[](0);
        string memory json = vm.readFile(CONFIG_PATH);
        string memory path = string.concat('.["', vm.toString(chainId), '"].stablecoins');
        return vm.keyExistsJson(json, path) ? vm.parseJsonAddressArray(json, path) : new address[](0);
    }

    /// @notice Patch only the `descriptor` key in `deployments/<chainId>.json`, preserving the rest
    /// of the stack's recorded addresses; write a minimal file if none exists yet.
    function _record(address descriptor) internal {
        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        if (vm.exists(path)) {
            vm.writeJson(vm.toString(descriptor), path, ".descriptor");
            console2.log("Updated .descriptor in", path);
        } else {
            string memory key = "descdeploy";
            vm.serializeUint(key, "chainId", block.chainid);
            string memory out = vm.serializeAddress(key, "descriptor", descriptor);
            vm.writeJson(out, path);
            console2.log("Wrote", path);
        }
    }
}
