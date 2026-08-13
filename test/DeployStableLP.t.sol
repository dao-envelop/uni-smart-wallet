// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DeployStableLP} from "../script/DeployStableLP.s.sol";
import {CreateManager} from "../script/CreateManager.s.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// Exposes CreateManager's internal config parsing for assertions (rebuilds the Stable InitParams the
/// way `_stableInit` does, minus impl lookup + encoding).
contract CreateManagerHarness is CreateManager {
    function parse(string memory json) external view returns (StableLPManager.InitParams memory p) {
        (PoolKey[] memory keys, int256[] memory lower, int256[] memory upper) = _parseStablePools(json);
        StableLPManager.StablePoolInit[] memory pools = new StableLPManager.StablePoolInit[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            pools[i] =
                StableLPManager.StablePoolInit({key: keys[i], tickLower: int24(lower[i]), tickUpper: int24(upper[i])});
        }
        p = StableLPManager.InitParams({
            owner: vm.parseJsonAddress(json, ".owner"),
            name: _readName(json, keccak256(bytes("stable"))),
            descriptor: address(0),
            pools: pools
        });
    }
}

contract DeployStableLPTest is Test {
    DeployStableLP internal deployer;
    IPoolManager internal pm = IPoolManager(address(0xBEEF)); // not called by constructors
    address internal admin = makeAddr("admin");

    function setUp() public {
        deployer = new DeployStableLP();
    }

    function test_deploy_wiresStackTogether() public {
        DeployStableLP.Deployment memory d = deployer.deploy(pm, admin);

        // FeeRedeemer is the treasury, owned by admin, pointing at the PoolManager.
        assertEq(d.feeRedeemer.owner(), admin, "feeRedeemer owner");
        assertEq(address(d.feeRedeemer.POOL_MANAGER()), address(pm), "feeRedeemer pm");

        // Both implementations tax fees to the FeeRedeemer and share the PoolManager.
        assertEq(d.impl.PROTOCOL_TREASURY(), address(d.feeRedeemer), "stable impl treasury == feeRedeemer");
        assertEq(address(d.impl.POOL_MANAGER()), address(pm), "stable impl pm");
        assertEq(d.volatileImpl.PROTOCOL_TREASURY(), address(d.feeRedeemer), "volatile impl treasury == feeRedeemer");
        assertEq(address(d.volatileImpl.POOL_MANAGER()), address(pm), "volatile impl pm");

        // Universal factory is owned by admin and allowlists BOTH products.
        assertEq(d.factory.owner(), admin, "factory owner == admin");
        assertTrue(d.factory.isImplementation(address(d.impl)), "stable impl allowlisted");
        assertTrue(d.factory.isImplementation(address(d.volatileImpl)), "volatile impl allowlisted");

        assertTrue(address(d.lens) != address(0), "lens");
        assertTrue(address(d.descriptor) != address(0), "descriptor");
    }

    function test_deploy_zeroAdminStillDeploys() public {
        // deploy() takes admin already resolved; just sanity that distinct instances are produced.
        DeployStableLP.Deployment memory a = deployer.deploy(pm, admin);
        DeployStableLP.Deployment memory b = deployer.deploy(pm, admin);
        assertTrue(address(a.factory) != address(b.factory), "distinct deploys");
    }

    function test_parseConfig_parallelArrays() public {
        CreateManagerHarness h = new CreateManagerHarness();
        string memory json = string(
            abi.encodePacked(
                '{"owner":"0x00000000000000000000000000000000000000aa",',
                '"currency0":["0x0000000000000000000000000000000000000010","0x0000000000000000000000000000000000000030"],',
                '"currency1":["0x0000000000000000000000000000000000000020","0x0000000000000000000000000000000000000040"],',
                '"fee":[500,100],',
                '"tickSpacing":[10,1],',
                '"hooks":["0x0000000000000000000000000000000000000000","0x0000000000000000000000000000000000000000"],',
                '"tickLower":[-100,-5],',
                '"tickUpper":[100,5]}'
            )
        );

        StableLPManager.InitParams memory p = h.parse(json);
        assertEq(p.owner, address(0xAA), "owner");
        assertEq(p.name, bytes32("Envelop StableLP"), "name defaults when key absent");
        assertEq(p.pools.length, 2, "pool count");

        assertEq(Currency.unwrap(p.pools[0].key.currency0), address(0x10), "c0[0]");
        assertEq(Currency.unwrap(p.pools[0].key.currency1), address(0x20), "c1[0]");
        assertEq(p.pools[0].key.fee, 500, "fee[0]");
        assertEq(p.pools[0].key.tickSpacing, int24(10), "spacing[0]");
        assertEq(address(p.pools[0].key.hooks), address(0), "hooks[0]");
        assertEq(p.pools[0].tickLower, int24(-100), "lower[0]");
        assertEq(p.pools[0].tickUpper, int24(100), "upper[0]");

        assertEq(p.pools[1].key.fee, 100, "fee[1]");
        assertEq(p.pools[1].tickLower, int24(-5), "lower[1]");
    }

    function test_parseConfig_lengthMismatchReverts() public {
        CreateManagerHarness h = new CreateManagerHarness();
        string memory json = string(
            abi.encodePacked(
                '{"owner":"0x00000000000000000000000000000000000000aa",',
                '"currency0":["0x0000000000000000000000000000000000000010"],',
                '"currency1":["0x0000000000000000000000000000000000000020"],',
                '"fee":[500],',
                '"tickSpacing":[10],',
                '"hooks":["0x0000000000000000000000000000000000000000"],',
                '"tickLower":[-100],',
                '"tickUpper":[100,200]}' // mismatched length
            )
        );
        vm.expectRevert(CreateManager.LengthMismatch.selector);
        h.parse(json);
    }

    function test_parseConfig_customNamePacked() public {
        CreateManagerHarness h = new CreateManagerHarness();
        string memory json = string(
            abi.encodePacked(
                '{"owner":"0x00000000000000000000000000000000000000aa",',
                '"name":"Acme USD Vault",',
                '"currency0":["0x0000000000000000000000000000000000000010"],',
                '"currency1":["0x0000000000000000000000000000000000000020"],',
                '"fee":[500],"tickSpacing":[10],',
                '"hooks":["0x0000000000000000000000000000000000000000"],',
                '"tickLower":[-100],"tickUpper":[100]}'
            )
        );
        assertEq(h.parse(json).name, bytes32("Acme USD Vault"), "custom name packed");
    }

    function test_parseConfig_nameTooLong_reverts() public {
        CreateManagerHarness h = new CreateManagerHarness();
        string memory json = string(
            abi.encodePacked(
                '{"owner":"0x00000000000000000000000000000000000000aa",',
                '"name":"This name is definitely longer than 31",', // 38 chars
                '"currency0":["0x0000000000000000000000000000000000000010"],',
                '"currency1":["0x0000000000000000000000000000000000000020"],',
                '"fee":[500],"tickSpacing":[10],',
                '"hooks":["0x0000000000000000000000000000000000000000"],',
                '"tickLower":[-100],"tickUpper":[100]}'
            )
        );
        vm.expectRevert(abi.encodeWithSelector(CreateManager.NameTooLong.selector, 38));
        h.parse(json);
    }
}

/// @dev Exposes the internal config parsing so tests can feed inline JSON without touching chain_params.
contract DeployConfigHarness is DeployStableLP {
    function readFlags(string memory json, string memory base) external view returns (Flags memory) {
        return _readFlags(json, base);
    }

    function readOracle(string memory json, string memory base) external view returns (OracleParams memory) {
        return _readOracle(json, base);
    }
}

/// @notice JSON parsing of the `deploy` toggle + oracle config.
contract DeployStableLPConfigTest is Test {
    DeployConfigHarness internal h;

    function setUp() public {
        h = new DeployConfigHarness();
    }

    /// @notice No `deploy` object ⇒ the legacy full set (oracle off) for backwards compatibility.
    function test_absentDeploy_defaultsToLegacyFullSet() public view {
        DeployStableLP.Flags memory f = h.readFlags('{"poolManager":"0x0000000000000000000000000000000000000001"}', "");
        assertTrue(
            f.feeRedeemer && f.stableImpl && f.volatileImpl && f.factory && f.lens && f.descriptor, "full set on"
        );
        assertFalse(f.oracle, "oracle stays off unless explicitly enabled");
    }

    /// @notice A `deploy` object that omits `openImpl` leaves it off (and an absent object likewise).
    function test_readFlags_openImplDefaultsOff() public view {
        DeployStableLP.Flags memory omitted = h.readFlags('{"deploy":{"stableImpl":true,"volatileImpl":true}}', "");
        assertFalse(omitted.openImpl, "omitted key means off");
        DeployStableLP.Flags memory legacy =
            h.readFlags('{"poolManager":"0x0000000000000000000000000000000000000001"}', "");
        assertFalse(legacy.openImpl, "legacy full set must not gain a third product");
        DeployStableLP.Flags memory asked = h.readFlags('{"deploy":{"openImpl":true}}', "");
        assertTrue(asked.openImpl, "explicit true means on");
    }

    /// @notice A `deploy` object enables exactly its true flags; omitted keys default to false.
    function test_subset_onlyOracleAndManagers() public view {
        DeployStableLP.Flags memory f =
            h.readFlags('{"deploy":{"stableImpl":true,"volatileImpl":true,"oracle":true}}', "");
        assertTrue(f.stableImpl && f.volatileImpl && f.oracle, "requested on");
        assertFalse(f.feeRedeemer || f.factory || f.lens || f.descriptor, "everything else off");
    }

    function test_oracle_readAndDefault() public view {
        DeployStableLP.OracleParams memory o = h.readOracle(
            '{"oracleMaxDeviationBps":250,"oracleSequencerFeed":"0x00000000000000000000000000000000000000Fe","oracleGracePeriod":1800}',
            ""
        );
        assertEq(uint256(o.maxDeviationBps), 250, "explicit bps");
        assertEq(o.sequencerFeed, address(0xFE), "explicit sequencer feed");
        assertEq(uint256(o.gracePeriod), 1800, "explicit grace");

        DeployStableLP.OracleParams memory d = h.readOracle("{}", "");
        assertEq(uint256(d.maxDeviationBps), 100, "default 1%");
        assertEq(d.sequencerFeed, address(0), "no sequencer feed by default");
        assertEq(uint256(d.gracePeriod), 3600, "default grace 1h");
    }
}

/// @notice Component-subset deploys via `deployComponents` (the flag-driven path behind `run()`), covering
/// the "only oracle + managers" case, the treasury fallback, and factory allowlisting.
contract DeployStableLPSubsetTest is Test {
    DeployStableLP internal deployer;
    IPoolManager internal pm = IPoolManager(address(0xBEEF)); // not called by constructors
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        deployer = new DeployStableLP();
    }

    function _flags(
        bool feeRedeemer,
        bool stableImpl,
        bool volatileImpl,
        bool factory,
        bool lens,
        bool descriptor,
        bool oracle
    ) internal pure returns (DeployStableLP.Flags memory) {
        return DeployStableLP.Flags({
            feeRedeemer: feeRedeemer,
            stableImpl: stableImpl,
            volatileImpl: volatileImpl,
            openImpl: false, // off by default; tests that want it set `.openImpl` on the result
            factory: factory,
            lens: lens,
            descriptor: descriptor,
            oracle: oracle
        });
    }

    function _noExisting() internal pure returns (DeployStableLP.Existing memory e) {}

    function _oracle(uint16 bps) internal pure returns (DeployStableLP.OracleParams memory) {
        return DeployStableLP.OracleParams({maxDeviationBps: bps, sequencerFeed: address(0), gracePeriod: 3600});
    }

    /// @notice The immediate need: deploy ONLY the oracle + the two manager impls, treasury from fallback.
    function test_oracleAndManagersOnly() public {
        DeployStableLP.Deployment memory d = deployer.deployComponents(
            pm,
            admin,
            _flags(false, true, true, false, false, false, true),
            treasury,
            _noExisting(),
            admin,
            _oracle(250),
            new address[](0)
        );

        // Only the requested components exist.
        assertEq(address(d.feeRedeemer), address(0), "no feeRedeemer");
        assertEq(address(d.factory), address(0), "no factory");
        assertEq(address(d.lens), address(0), "no lens");
        assertEq(address(d.descriptor), address(0), "no descriptor");

        // Impls built against the fallback treasury.
        assertTrue(address(d.impl) != address(0), "stable impl");
        assertTrue(address(d.volatileImpl) != address(0), "volatile impl");
        assertEq(d.impl.PROTOCOL_TREASURY(), treasury, "stable treasury == fallback");
        assertEq(d.volatileImpl.PROTOCOL_TREASURY(), treasury, "volatile treasury == fallback");

        // Oracle owned by admin with the configured tolerance.
        assertTrue(address(d.oracle) != address(0), "oracle");
        assertEq(d.oracle.owner(), admin, "oracle owner == admin");
        assertEq(uint256(d.oracle.maxDeviationBps()), 250, "oracle tolerance");
    }

    /// @notice A fresh FeeRedeemer this run overrides any fallback treasury for the impls.
    function test_freshFeeRedeemerOverridesFallbackTreasury() public {
        DeployStableLP.Deployment memory d = deployer.deployComponents(
            pm,
            admin,
            _flags(true, true, false, false, false, false, false),
            treasury,
            _noExisting(),
            admin,
            _oracle(100),
            new address[](0)
        );
        assertEq(d.impl.PROTOCOL_TREASURY(), address(d.feeRedeemer), "treasury == fresh feeRedeemer, not fallback");
    }

    /// @notice Building an impl with neither a fresh nor a fallback treasury must revert.
    function test_treasuryMissing_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DeployStableLP.TreasuryMissing.selector, block.chainid));
        deployer.deployComponents(
            pm,
            admin,
            _flags(false, true, false, false, false, false, false),
            address(0),
            _noExisting(),
            admin,
            _oracle(100),
            new address[](0)
        );
    }

    /// @notice The third product (hooks allowed) is off unless asked for, and when asked for it is
    /// deployed with the same treasury/PoolManager wiring and blessed on a factory built this run.
    function test_openImpl_offByDefault_onWhenRequested() public {
        DeployStableLP.Flags memory off = _flags(false, true, true, true, false, false, false);
        DeployStableLP.Deployment memory d0 =
            deployer.deployComponents(pm, admin, off, treasury, _noExisting(), admin, _oracle(100), new address[](0));
        assertEq(address(d0.openImpl), address(0), "not deployed unless requested");
        assertFalse(d0.factory.isImplementation(address(0)), "zero never allowlisted");

        DeployStableLP.Flags memory on = _flags(false, true, true, true, false, false, false);
        on.openImpl = true;
        DeployStableLP.Deployment memory d =
            deployer.deployComponents(pm, admin, on, treasury, _noExisting(), admin, _oracle(100), new address[](0));
        assertTrue(address(d.openImpl) != address(0), "open impl deployed");
        assertEq(d.openImpl.ORACLE_TYPE(), 3002, "own oracle type");
        assertEq(d.openImpl.PROTOCOL_TREASURY(), treasury, "open treasury == fallback");
        assertEq(address(d.openImpl.POOL_MANAGER()), address(pm), "open impl pm");
        assertTrue(d.factory.isImplementation(address(d.openImpl)), "open impl allowlisted on a fresh factory");
        // and the other two are still there — _implList grew rather than replaced
        assertTrue(d.factory.isImplementation(address(d.impl)), "stable still allowlisted");
        assertTrue(d.factory.isImplementation(address(d.volatileImpl)), "volatile still allowlisted");
    }

    /// @notice A factory deployed this run allowlists impls carried from the existing deployments file.
    function test_factoryAllowlistsExistingImpls() public {
        DeployStableLP.Existing memory e = _noExisting();
        e.exists = true;
        e.impl = makeAddr("existingStable");
        e.volatileImpl = makeAddr("existingVolatile");

        DeployStableLP.Deployment memory d = deployer.deployComponents(
            pm,
            admin,
            _flags(false, false, false, true, false, false, false),
            treasury,
            e,
            admin,
            _oracle(100),
            new address[](0)
        );
        assertTrue(d.factory.isImplementation(e.impl), "existing stable allowlisted");
        assertTrue(d.factory.isImplementation(e.volatileImpl), "existing volatile allowlisted");
    }

    /// @notice When the factory is NOT redeployed, fresh impls are auto-allowlisted on the existing factory
    /// the broadcaster owns.
    function test_autoAllowlistFreshImplsOnExistingFactory() public {
        // Under `forge script --broadcast` the `setImplementation` tx is sent from the broadcaster EOA;
        // in this direct unit call the actual caller is the script contract (`deployer`), so the factory
        // must be owned by `deployer` and the broadcaster arg set to it for the ownership guard to pass.
        LPManagerFactory factory = new LPManagerFactory(address(deployer), new address[](0));
        DeployStableLP.Existing memory e = _noExisting();
        e.exists = true;
        e.factory = address(factory);

        DeployStableLP.Deployment memory d = deployer.deployComponents(
            pm,
            admin,
            _flags(false, true, true, false, false, false, false),
            treasury,
            e,
            address(deployer),
            _oracle(100),
            new address[](0)
        );
        assertTrue(factory.isImplementation(address(d.impl)), "fresh stable auto-allowlisted");
        assertTrue(factory.isImplementation(address(d.volatileImpl)), "fresh volatile auto-allowlisted");
    }

    /// @notice If the broadcaster is not the factory owner, auto-allowlist is skipped (no revert).
    function test_autoAllowlistSkippedWhenNotOwner() public {
        LPManagerFactory factory = new LPManagerFactory(makeAddr("someoneElse"), new address[](0));
        DeployStableLP.Existing memory e = _noExisting();
        e.exists = true;
        e.factory = address(factory);

        DeployStableLP.Deployment memory d = deployer.deployComponents(
            pm,
            admin,
            _flags(false, true, false, false, false, false, false),
            treasury,
            e,
            address(this),
            _oracle(100),
            new address[](0)
        );
        assertFalse(factory.isImplementation(address(d.impl)), "not allowlisted (broadcaster != owner)");
    }
}
