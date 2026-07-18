// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FeeRedeemer} from "../src/FeeRedeemer.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {UniLens} from "../src/UniLens.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";

/// @notice Deploys the full LP-manager stack for the current chain (Stable + Volatile impls behind one
/// universal `LPManagerFactory`).
///
/// Order matters: `FeeRedeemer` is the protocol treasury, so it is deployed first and its address is
/// passed as `treasury_` to both manager implementations. The universal factory is allowlisted with
/// both impls. Managers themselves are NOT created here — users clone them via the factory (see
/// `CreateManager.s.sol`).
///
/// Per-chain `poolManager` (required) and `initialOwner` (optional protocol admin) come from
/// `script/chain_params.json` keyed by `block.chainid`. A zero `initialOwner` falls back to the
/// broadcaster — softer than `DeployWallet`, which reverts.
///
///   forge script script/DeployStableLP.s.sol --rpc-url $RPC \
///     --sender $SENDER --account $KEYSTORE --broadcast
contract DeployStableLP is Script {
    string internal constant CONFIG_PATH = "./script/chain_params.json";

    error ChainConfigMissing(uint256 chainId);
    error InvalidPoolManager(uint256 chainId);

    struct Deployment {
        FeeRedeemer feeRedeemer;
        StableLPManager impl;
        VolatileLPManager volatileImpl;
        LPManagerFactory factory;
        UniLens lens;
        WalletPositionDescriptor descriptor;
    }

    function run() external returns (Deployment memory d) {
        (IPoolManager pm, address initialOwner, string memory name) = loadConfig(block.chainid);

        vm.startBroadcast();
        address admin = initialOwner == address(0) ? msg.sender : initialOwner;
        d = deploy(pm, admin);
        vm.stopBroadcast();

        _log(pm, admin, name, d);
        _write(pm, name, d);
    }

    /// @notice Deploy the stack contracts wired together. Public so tests can drive it. The universal
    /// factory is allowlisted with both product implementations (Stable + Volatile).
    function deploy(IPoolManager pm, address admin) public returns (Deployment memory d) {
        d.feeRedeemer = new FeeRedeemer(pm, admin);
        d.impl = new StableLPManager(pm, address(d.feeRedeemer));
        d.volatileImpl = new VolatileLPManager(pm, address(d.feeRedeemer));
        address[] memory impls = new address[](2);
        impls[0] = address(d.impl);
        impls[1] = address(d.volatileImpl);
        d.factory = new LPManagerFactory(admin, impls);
        d.lens = new UniLens();
        d.descriptor = new WalletPositionDescriptor();
    }

    function loadConfig(uint256 chainId)
        public
        view
        returns (IPoolManager poolManager, address initialOwner, string memory name)
    {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory base = string.concat('.["', vm.toString(chainId), '"]');
        string memory pmPath = string.concat(base, ".poolManager");
        if (!vm.keyExistsJson(json, pmPath)) revert ChainConfigMissing(chainId);

        address pm = vm.parseJsonAddress(json, pmPath);
        if (pm == address(0)) revert InvalidPoolManager(chainId);
        poolManager = IPoolManager(pm);

        string memory ioPath = string.concat(base, ".initialOwner");
        initialOwner = vm.keyExistsJson(json, ioPath) ? vm.parseJsonAddress(json, ioPath) : address(0);

        string memory namePath = string.concat(base, ".name");
        name = vm.keyExistsJson(json, namePath) ? vm.parseJsonString(json, namePath) : "";
    }

    function _log(IPoolManager pm, address admin, string memory name, Deployment memory d) internal pure {
        console2.log("== StableLP stack deployed ==");
        console2.log("chain name:    ", name);
        console2.log("PoolManager:   ", address(pm));
        console2.log("admin/treasury owner:", admin);
        console2.log("FeeRedeemer:   ", address(d.feeRedeemer));
        console2.log("impl (stable): ", address(d.impl));
        console2.log("volatileImpl:  ", address(d.volatileImpl));
        console2.log("LPManagerFactory:", address(d.factory));
        console2.log("UniLens:       ", address(d.lens));
        console2.log("Descriptor:    ", address(d.descriptor));
    }

    function _write(IPoolManager pm, string memory name, Deployment memory d) internal {
        string memory key = "stablelp";
        vm.serializeString(key, "name", name);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "fromBlock", block.number); // factory deploy block — getLogs start
        vm.serializeAddress(key, "poolManager", address(pm));
        vm.serializeAddress(key, "feeRedeemer", address(d.feeRedeemer));
        vm.serializeAddress(key, "impl", address(d.impl));
        vm.serializeAddress(key, "volatileImpl", address(d.volatileImpl));
        vm.serializeAddress(key, "factory", address(d.factory));
        vm.serializeAddress(key, "lens", address(d.lens));
        string memory out = vm.serializeAddress(key, "descriptor", address(d.descriptor));
        vm.writeJson(out, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}
