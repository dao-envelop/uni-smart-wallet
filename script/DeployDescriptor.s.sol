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
/// existing clones. The descriptor has no constructor args, so there is no per-chain config to
/// read. The new address is recorded into `deployments/<chainId>.json` (`.descriptor`); afterwards
/// wire it into each wallet/manager with the `cast send … setPositionDescriptor` command from
/// `script/README.md` (the NFT owner must sign that call).
///
///   forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url $RPC \
///     --account $KEYSTORE --sender $SENDER --broadcast --verify
contract DeployDescriptor is Script {
    function run() external returns (WalletPositionDescriptor descriptor) {
        vm.startBroadcast();
        descriptor = deploy();
        vm.stopBroadcast();

        console2.log("Chain ID:   ", block.chainid);
        console2.log("Descriptor: ", address(descriptor));

        _record(address(descriptor));
    }

    /// @notice Deploy the descriptor. Public + side-effect-free so tests can drive it without
    /// broadcasting or touching the filesystem.
    function deploy() public returns (WalletPositionDescriptor) {
        return new WalletPositionDescriptor();
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
