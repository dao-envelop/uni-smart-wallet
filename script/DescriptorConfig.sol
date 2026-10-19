// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

/// @notice Reads the {WalletPositionDescriptor} constructor inputs for a chain from
/// `script/chain_params.json` (task_055), shared by `DeployDescriptor` and `DeployStableLP`:
///
///   "stablecoins": ["0x…"],                         // $1 allowlist
///   "descriptor": {
///     "weth": "0x…",                                // aliased to native for pricing
///     "nativeSymbol": "ETH",
///     "references": [                               // one of v3Pool / v4 per entry
///       { "symbol": "ARB", "token": "0x…", "v3Pool": "0x…" },
///       { "symbol": "ETH", "token": "0x0…0", "v4": { "currency0": "0x…", "currency1": "0x…", "fee": 500, "tickSpacing": 10 } }
///     ]
///   }
///
/// Missing keys ⇒ empty allowlist / no references / native symbol "ETH".
abstract contract DescriptorConfig is Script {
    string internal constant DESCRIPTOR_CONFIG_PATH = "./script/chain_params.json";

    struct DescriptorParams {
        address weth;
        string nativeSymbol;
        address[] stablecoins;
        WalletPositionDescriptor.RefInit[] refs;
    }

    function readDescriptorParams(uint256 chainId) public view returns (DescriptorParams memory p) {
        p.nativeSymbol = "ETH";
        if (!vm.exists(DESCRIPTOR_CONFIG_PATH)) return p;
        string memory json = vm.readFile(DESCRIPTOR_CONFIG_PATH);
        string memory base = string.concat('.["', vm.toString(chainId), '"]');
        string memory sPath = string.concat(base, ".stablecoins");
        if (vm.keyExistsJson(json, sPath)) p.stablecoins = vm.parseJsonAddressArray(json, sPath);
        string memory d = string.concat(base, ".descriptor");
        if (!vm.keyExistsJson(json, d)) return p;
        if (vm.keyExistsJson(json, string.concat(d, ".weth"))) {
            p.weth = vm.parseJsonAddress(json, string.concat(d, ".weth"));
        }
        if (vm.keyExistsJson(json, string.concat(d, ".nativeSymbol"))) {
            p.nativeSymbol = vm.parseJsonString(json, string.concat(d, ".nativeSymbol"));
        }
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(d, ".references[", vm.toString(n), "]"))) {
            ++n;
        }
        p.refs = new WalletPositionDescriptor.RefInit[](n);
        for (uint256 i = 0; i < n; ++i) {
            p.refs[i] = _readRef(json, string.concat(d, ".references[", vm.toString(i), "]"));
        }
    }

    function _readRef(string memory json, string memory r)
        private
        view
        returns (WalletPositionDescriptor.RefInit memory ref)
    {
        ref.token = vm.parseJsonAddress(json, string.concat(r, ".token"));
        if (vm.keyExistsJson(json, string.concat(r, ".v3Pool"))) {
            ref.v3Pool = vm.parseJsonAddress(json, string.concat(r, ".v3Pool"));
        } else {
            string memory k = string.concat(r, ".v4");
            ref.v4Key = PoolKey({
                currency0: Currency.wrap(vm.parseJsonAddress(json, string.concat(k, ".currency0"))),
                currency1: Currency.wrap(vm.parseJsonAddress(json, string.concat(k, ".currency1"))),
                fee: uint24(vm.parseJsonUint(json, string.concat(k, ".fee"))),
                tickSpacing: int24(vm.parseJsonInt(json, string.concat(k, ".tickSpacing"))),
                hooks: IHooks(address(0))
            });
        }
    }
}
