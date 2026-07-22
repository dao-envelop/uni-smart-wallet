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
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";

/// @notice Deploys the LP-manager stack for the current chain — either the FULL set or an arbitrary
/// SUBSET selected from `script/chain_params.json`.
///
/// ### Component selection (the `deploy` object)
/// Each chain entry may carry an optional `deploy` object of per-component booleans:
///
///   "deploy": { "feeRedeemer": false, "stableImpl": true, "volatileImpl": true,
///               "factory": false, "lens": false, "descriptor": false, "oracle": true }
///
/// A missing flag defaults to `false`. If the whole `deploy` object is absent, the LEGACY full set is
/// deployed (feeRedeemer + both impls + factory + lens + descriptor; oracle stays off) — so existing
/// chain configs keep behaving exactly as before. This lets you ship, e.g., "only the oracle and the
/// two manager impls" without redeploying (and orphaning) the factory/lens/descriptor.
///
/// ### Dependency resolution
/// - The manager impls need a treasury (the `FeeRedeemer`). When `feeRedeemer` is NOT deployed this run,
///   the treasury is resolved as: `deploy`-chain `treasury` override → else `.feeRedeemer` from the
///   existing `deployments/<chainId>.json` → else revert {TreasuryMissing}.
/// - The factory allowlists the impls. When `factory` is deployed this run it blesses whichever impls are
///   available (fresh this run, else `.impl`/`.volatileImpl` from the deployments file). When the factory
///   is NOT redeployed but fresh impls WERE deployed, the script best-effort allowlists them on the
///   existing `.factory` — but only if the broadcaster is the factory owner (otherwise it logs a warning
///   and you must call `setImplementation` manually).
/// - The oracle ({ChainlinkPriceOracle}) is standalone: it is deployed and recorded, then wired into each
///   manager clone later via the owner-only `setPriceOracle` (per-clone, not done here). Its inputs come
///   from the chain's `oracleMaxDeviationBps` (default 100 = 1%), `oracleSequencerFeed` (L2 Sequencer
///   Uptime Feed; omitted ⇒ no sequencer gate), and `oracleGracePeriod` (default 3600s).
///
/// ### Output
/// Addresses are MERGED into `deployments/<chainId>.json`: keys for components deployed this run are
/// (over)written, all other previously-recorded keys are preserved.
///
/// Per-chain `poolManager` (required) and `initialOwner` (optional protocol admin) come from
/// `script/chain_params.json` keyed by `block.chainid`. A zero `initialOwner` falls back to the
/// broadcaster.
///
///   forge script script/DeployStableLP.s.sol --sig "run()" --rpc-url $RPC \
///     --sender $SENDER --account $KEYSTORE --broadcast
contract DeployStableLP is Script {
    string internal constant CONFIG_PATH = "./script/chain_params.json";
    uint16 internal constant DEFAULT_ORACLE_MAX_DEVIATION_BPS = 100; // 1%
    uint32 internal constant DEFAULT_SEQUENCER_GRACE_PERIOD = 3600; // 1h (Chainlink L2 best practice)

    error ChainConfigMissing(uint256 chainId);
    error InvalidPoolManager(uint256 chainId);
    error TreasuryMissing(uint256 chainId);

    /// @notice ChainlinkPriceOracle constructor inputs (resolved from chain_params.json).
    struct OracleParams {
        uint16 maxDeviationBps;
        address sequencerFeed; // L2 Sequencer Uptime Feed; zero ⇒ no sequencer gate (L1 / unsupported)
        uint32 gracePeriod;
    }

    /// @notice Which components to deploy this run.
    struct Flags {
        bool feeRedeemer;
        bool stableImpl;
        bool volatileImpl;
        bool factory;
        bool lens;
        bool descriptor;
        bool oracle;
    }

    /// @notice Addresses already recorded in `deployments/<chainId>.json` (all zero if the file is absent).
    struct Existing {
        bool exists;
        address feeRedeemer;
        address impl;
        address volatileImpl;
        address factory;
        address lens;
        address descriptor;
        address oracle;
        uint256 fromBlock;
    }

    struct Deployment {
        FeeRedeemer feeRedeemer;
        StableLPManager impl;
        VolatileLPManager volatileImpl;
        LPManagerFactory factory;
        UniLens lens;
        WalletPositionDescriptor descriptor;
        ChainlinkPriceOracle oracle;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = loadConfig(block.chainid);
        address admin = c.initialOwner == address(0) ? msg.sender : c.initialOwner;
        address broadcaster = msg.sender;
        Existing memory existing = _readExisting(block.chainid);

        // Treasury for the impls when we are NOT minting a fresh FeeRedeemer this run.
        address treasury = c.treasury != address(0) ? c.treasury : existing.feeRedeemer;

        vm.startBroadcast();
        d = deployComponents(c.poolManager, admin, c.flags, treasury, existing, broadcaster, c.oracle, c.stablecoins);
        vm.stopBroadcast();

        _log(c.poolManager, admin, c.name, c.flags, d);
        _write(c.poolManager, c.name, c.flags, d, existing);
    }

    /// @notice Backwards-compatible FULL deploy (every component, oracle included), wired together and
    /// filesystem-free. Public so unit tests can drive it without config/deployments files.
    function deploy(IPoolManager pm, address admin) public returns (Deployment memory d) {
        Flags memory all = Flags({
            feeRedeemer: true,
            stableImpl: true,
            volatileImpl: true,
            factory: true,
            lens: true,
            descriptor: true,
            oracle: true
        });
        OracleParams memory oracle = OracleParams({
            maxDeviationBps: DEFAULT_ORACLE_MAX_DEVIATION_BPS,
            sequencerFeed: address(0),
            gracePeriod: DEFAULT_SEQUENCER_GRACE_PERIOD
        });
        return deployComponents(pm, admin, all, address(0), _emptyExisting(), admin, oracle, new address[](0));
    }

    /// @notice Deploy exactly the components enabled in `flags`, resolving prerequisites (treasury for the
    /// impls, impl allowlist for the factory) from fresh deploys first, then from `existing`.
    /// @param pm The chain's Uniswap V4 PoolManager.
    /// @param admin Protocol admin: owner of FeeRedeemer / factory / oracle.
    /// @param flags Per-component on/off switches.
    /// @param treasury Fallback treasury (used only when `flags.feeRedeemer` is false and an impl is built).
    /// @param existing Previously-recorded addresses (for factory allowlisting when impls aren't fresh).
    /// @param broadcaster The tx sender; must equal the existing factory's owner to auto-allowlist on it.
    /// @param oracle Oracle constructor inputs (deviation tolerance, L2 sequencer feed + grace period).
    function deployComponents(
        IPoolManager pm,
        address admin,
        Flags memory flags,
        address treasury,
        Existing memory existing,
        address broadcaster,
        OracleParams memory oracle,
        address[] memory stablecoins
    ) public returns (Deployment memory d) {
        // 1. Treasury: a fresh FeeRedeemer overrides any fallback.
        address treasuryAddr = treasury;
        if (flags.feeRedeemer) {
            d.feeRedeemer = new FeeRedeemer(pm, admin);
            treasuryAddr = address(d.feeRedeemer);
        }

        // 2. Manager implementations (need a treasury).
        if (flags.stableImpl || flags.volatileImpl) {
            if (treasuryAddr == address(0)) revert TreasuryMissing(block.chainid);
        }
        if (flags.stableImpl) d.impl = new StableLPManager(pm, treasuryAddr);
        if (flags.volatileImpl) d.volatileImpl = new VolatileLPManager(pm, treasuryAddr);

        // 3. Factory: build allowlisting available impls, or best-effort allowlist fresh impls on the old one.
        address stableAddr = address(d.impl) != address(0) ? address(d.impl) : existing.impl;
        address volatileAddr = address(d.volatileImpl) != address(0) ? address(d.volatileImpl) : existing.volatileImpl;
        if (flags.factory) {
            d.factory = new LPManagerFactory(admin, _implList(stableAddr, volatileAddr));
        } else {
            _allowlistFreshImpls(existing.factory, address(d.impl), address(d.volatileImpl), broadcaster);
        }

        // 4. Standalone components.
        if (flags.lens) d.lens = new UniLens();
        if (flags.descriptor) d.descriptor = new WalletPositionDescriptor(stablecoins);
        if (flags.oracle) {
            d.oracle = new ChainlinkPriceOracle(admin, oracle.maxDeviationBps, oracle.sequencerFeed, oracle.gracePeriod);
        }
    }

    /// @dev Best-effort: bless freshly-deployed impls on an already-deployed factory the broadcaster owns.
    function _allowlistFreshImpls(address factory, address stableImpl, address volatileImpl, address broadcaster)
        internal
    {
        if (stableImpl == address(0) && volatileImpl == address(0)) return; // no fresh impls ⇒ nothing to bless
        if (factory == address(0)) {
            console2.log("WARN: fresh impls deployed but no factory to allowlist them on; set .factory or deploy one");
            return;
        }
        try LPManagerFactory(factory).owner() returns (address o) {
            if (o != broadcaster) {
                console2.log("WARN: broadcaster is not the factory owner; skipping auto-allowlist. Factory owner:", o);
                return;
            }
        } catch {
            console2.log("WARN: could not read factory owner (stale .factory?); skipping auto-allowlist:", factory);
            return;
        }
        if (stableImpl != address(0)) {
            LPManagerFactory(factory).setImplementation(stableImpl, true);
            console2.log("Allowlisted stable impl on factory:", stableImpl);
        }
        if (volatileImpl != address(0)) {
            LPManagerFactory(factory).setImplementation(volatileImpl, true);
            console2.log("Allowlisted volatile impl on factory:", volatileImpl);
        }
    }

    function _implList(address stableAddr, address volatileAddr) internal pure returns (address[] memory impls) {
        uint256 n;
        if (stableAddr != address(0)) ++n;
        if (volatileAddr != address(0)) ++n;
        impls = new address[](n);
        uint256 i;
        if (stableAddr != address(0)) impls[i++] = stableAddr;
        if (volatileAddr != address(0)) impls[i++] = volatileAddr;
    }

    // ────────── config ──────────

    struct Config {
        IPoolManager poolManager;
        address initialOwner;
        address treasury;
        string name;
        Flags flags;
        OracleParams oracle;
        address[] stablecoins; // per-chain $1 allowlist for the descriptor
    }

    function loadConfig(uint256 chainId) public view returns (Config memory c) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory base = string.concat('.["', vm.toString(chainId), '"]');
        string memory pmPath = string.concat(base, ".poolManager");
        if (!vm.keyExistsJson(json, pmPath)) revert ChainConfigMissing(chainId);

        address pm = vm.parseJsonAddress(json, pmPath);
        if (pm == address(0)) revert InvalidPoolManager(chainId);
        c.poolManager = IPoolManager(pm);

        c.initialOwner = _optAddr(json, string.concat(base, ".initialOwner"));
        c.treasury = _optAddr(json, string.concat(base, ".treasury"));
        c.name = _optStr(json, string.concat(base, ".name"));
        c.flags = _readFlags(json, base);
        c.oracle = _readOracle(json, base);
        c.stablecoins = _optAddrArray(json, string.concat(base, ".stablecoins"));
    }

    /// @dev Read the `deploy` toggle object; a missing object ⇒ the legacy full set (oracle off).
    function _readFlags(string memory json, string memory base) internal view returns (Flags memory f) {
        string memory deployPath = string.concat(base, ".deploy");
        if (!vm.keyExistsJson(json, deployPath)) {
            return Flags({
                feeRedeemer: true,
                stableImpl: true,
                volatileImpl: true,
                factory: true,
                lens: true,
                descriptor: true,
                oracle: false
            });
        }
        f.feeRedeemer = _optBool(json, string.concat(deployPath, ".feeRedeemer"));
        f.stableImpl = _optBool(json, string.concat(deployPath, ".stableImpl"));
        f.volatileImpl = _optBool(json, string.concat(deployPath, ".volatileImpl"));
        f.factory = _optBool(json, string.concat(deployPath, ".factory"));
        f.lens = _optBool(json, string.concat(deployPath, ".lens"));
        f.descriptor = _optBool(json, string.concat(deployPath, ".descriptor"));
        f.oracle = _optBool(json, string.concat(deployPath, ".oracle"));
    }

    /// @dev Read the oracle config: deviation tolerance + optional L2 sequencer feed / grace period.
    function _readOracle(string memory json, string memory base) internal view returns (OracleParams memory o) {
        string memory bpsPath = string.concat(base, ".oracleMaxDeviationBps");
        o.maxDeviationBps = vm.keyExistsJson(json, bpsPath)
            ? uint16(vm.parseJsonUint(json, bpsPath))
            : DEFAULT_ORACLE_MAX_DEVIATION_BPS;
        o.sequencerFeed = _optAddr(json, string.concat(base, ".oracleSequencerFeed"));
        string memory gpPath = string.concat(base, ".oracleGracePeriod");
        o.gracePeriod =
            vm.keyExistsJson(json, gpPath) ? uint32(vm.parseJsonUint(json, gpPath)) : DEFAULT_SEQUENCER_GRACE_PERIOD;
    }

    function _optAddr(string memory json, string memory path) internal view returns (address) {
        return vm.keyExistsJson(json, path) ? vm.parseJsonAddress(json, path) : address(0);
    }

    /// @dev Optional address array (e.g. the descriptor stablecoin allowlist); missing key ⇒ empty.
    function _optAddrArray(string memory json, string memory path) internal view returns (address[] memory) {
        return vm.keyExistsJson(json, path) ? vm.parseJsonAddressArray(json, path) : new address[](0);
    }

    function _optStr(string memory json, string memory path) internal view returns (string memory) {
        return vm.keyExistsJson(json, path) ? vm.parseJsonString(json, path) : "";
    }

    function _optBool(string memory json, string memory path) internal view returns (bool) {
        return vm.keyExistsJson(json, path) ? vm.parseJsonBool(json, path) : false;
    }

    // ────────── deployments file (read for merge + prerequisite resolution) ──────────

    function _readExisting(uint256 chainId) internal view returns (Existing memory e) {
        string memory path = string.concat("./deployments/", vm.toString(chainId), ".json");
        if (!vm.exists(path)) return e;
        string memory json = vm.readFile(path);
        e.exists = true;
        e.feeRedeemer = _optAddr(json, ".feeRedeemer");
        e.impl = _optAddr(json, ".impl");
        e.volatileImpl = _optAddr(json, ".volatileImpl");
        e.factory = _optAddr(json, ".factory");
        e.lens = _optAddr(json, ".lens");
        e.descriptor = _optAddr(json, ".descriptor");
        e.oracle = _optAddr(json, ".oracle");
        e.fromBlock = vm.keyExistsJson(json, ".fromBlock") ? vm.parseJsonUint(json, ".fromBlock") : 0;
    }

    function _emptyExisting() internal pure returns (Existing memory e) {}

    // ────────── logging + output ──────────

    function _log(IPoolManager pm, address admin, string memory name, Flags memory f, Deployment memory d)
        internal
        pure
    {
        console2.log("== LP stack deploy ==");
        console2.log("chain name:    ", name);
        console2.log("PoolManager:   ", address(pm));
        console2.log("admin/owner:   ", admin);
        if (f.feeRedeemer) console2.log("FeeRedeemer:   ", address(d.feeRedeemer));
        if (f.stableImpl) console2.log("impl (stable): ", address(d.impl));
        if (f.volatileImpl) console2.log("volatileImpl:  ", address(d.volatileImpl));
        if (f.factory) console2.log("LPManagerFactory:", address(d.factory));
        if (f.lens) console2.log("UniLens:       ", address(d.lens));
        if (f.descriptor) console2.log("Descriptor:    ", address(d.descriptor));
        if (f.oracle) console2.log("Oracle:        ", address(d.oracle));
    }

    /// @dev Merge this run's deployed addresses into `deployments/<chainId>.json`: components deployed now
    /// are (over)written; every other previously-recorded key is carried forward.
    function _write(IPoolManager pm, string memory name, Flags memory f, Deployment memory d, Existing memory existing)
        internal
    {
        // Merge into `existing` in place (freshly-deployed overrides carried-forward) to keep stack shallow.
        if (address(d.feeRedeemer) != address(0)) existing.feeRedeemer = address(d.feeRedeemer);
        if (address(d.impl) != address(0)) existing.impl = address(d.impl);
        if (address(d.volatileImpl) != address(0)) existing.volatileImpl = address(d.volatileImpl);
        if (address(d.factory) != address(0)) existing.factory = address(d.factory);
        if (address(d.lens) != address(0)) existing.lens = address(d.lens);
        if (address(d.descriptor) != address(0)) existing.descriptor = address(d.descriptor);
        if (address(d.oracle) != address(0)) existing.oracle = address(d.oracle);
        // fromBlock tracks the factory deploy block (getLogs start); refresh it only when we redeploy it.
        if (f.factory || !existing.exists) existing.fromBlock = block.number;

        string memory k = "out";
        string memory out;
        out = vm.serializeUint(k, "chainId", block.chainid);
        out = vm.serializeString(k, "name", name);
        out = vm.serializeAddress(k, "poolManager", address(pm));
        out = vm.serializeUint(k, "fromBlock", existing.fromBlock);
        if (existing.feeRedeemer != address(0)) out = vm.serializeAddress(k, "feeRedeemer", existing.feeRedeemer);
        if (existing.impl != address(0)) out = vm.serializeAddress(k, "impl", existing.impl);
        if (existing.volatileImpl != address(0)) out = vm.serializeAddress(k, "volatileImpl", existing.volatileImpl);
        if (existing.factory != address(0)) out = vm.serializeAddress(k, "factory", existing.factory);
        if (existing.lens != address(0)) out = vm.serializeAddress(k, "lens", existing.lens);
        if (existing.descriptor != address(0)) out = vm.serializeAddress(k, "descriptor", existing.descriptor);
        if (existing.oracle != address(0)) out = vm.serializeAddress(k, "oracle", existing.oracle);

        vm.writeJson(out, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}
