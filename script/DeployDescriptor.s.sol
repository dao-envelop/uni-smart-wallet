// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DescriptorConfig} from "./DescriptorConfig.sol";
import {console2} from "forge-std/console2.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

/// @notice Deploys a standalone {WalletPositionDescriptor} — the shared on-chain `tokenURI`
/// renderer used by the NFT-owned LP managers (`StableLPManager`, `VolatileLPManager`, Open).
///
/// Use this to ship a new descriptor without re-running the whole StableLP stack
/// (`DeployStableLP.s.sol`), which would also redeploy the factory/impl/treasury and orphan
/// existing clones. Constructor inputs come from `chain_params.json` (see {DescriptorConfig}): the
/// `$1` stablecoin allowlist, WETH, the native ticker and the reference pools (task_055). The admin
/// of the allowlist / reference registry (Ownable2Step) is `.initialOwner`, or the broadcaster when
/// that is zero. The new address is recorded into `deployments/<chainId>.json` (`.descriptor`);
/// afterwards each manager owner re-points with `setPositionDescriptor` (see `script/README.md`).
///
///   forge script script/DeployDescriptor.s.sol --sig "run()" --rpc-url $RPC \
///     --account $KEYSTORE --sender $SENDER --broadcast --verify
contract DeployDescriptor is DescriptorConfig {
    function run() external returns (WalletPositionDescriptor descriptor) {
        DescriptorParams memory p = readDescriptorParams(block.chainid);
        address owner = _owner(block.chainid);
        if (owner == address(0)) owner = msg.sender;
        address pm = vm.parseJsonAddress(
            vm.readFile(DESCRIPTOR_CONFIG_PATH), string.concat('.["', vm.toString(block.chainid), '"].poolManager')
        );

        vm.startBroadcast();
        descriptor = deploy(IPoolManager(pm), owner, p);
        vm.stopBroadcast();

        console2.log("Chain ID:   ", block.chainid);
        console2.log("Descriptor: ", address(descriptor));
        console2.log("Owner:      ", owner);
        console2.log("Stablecoins:", p.stablecoins.length);
        console2.log("References: ", p.refs.length);

        _record(address(descriptor));
    }

    /// @notice Deploy the descriptor. Public + side-effect-free so tests can drive it.
    function deploy(IPoolManager pm, address owner, DescriptorParams memory p)
        public
        returns (WalletPositionDescriptor)
    {
        return new WalletPositionDescriptor(pm, owner, p.weth, p.nativeSymbol, p.stablecoins, p.refs);
    }

    function _owner(uint256 chainId) internal view returns (address) {
        string memory json = vm.readFile(DESCRIPTOR_CONFIG_PATH);
        string memory path = string.concat('.["', vm.toString(chainId), '"].initialOwner');
        return vm.keyExistsJson(json, path) ? vm.parseJsonAddress(json, path) : address(0);
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
