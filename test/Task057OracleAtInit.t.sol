// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {FactoryHelper} from "./helpers/FactoryHelper.sol";
import {MockERC20, MockPriceOracle} from "./helpers/Mocks.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {OpenVolatileLPManager} from "../src/OpenVolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {LPManagerFactory} from "../src/LPManagerFactory.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice task_057: the operator price guard can be wired at `initialize`, like the descriptor. Zero
/// keeps the old behaviour (no oracle ⇒ operators fail-closed); a non-zero oracle is set through the same
/// internal path as `setPriceOracle`, so the `PriceOracleSet` event an indexer reads is identical.
contract Task057OracleAtInitTest is StableLPTestBase {
    MockPriceOracle internal oracle;
    VolatileLPManager internal volImpl;
    OpenVolatileLPManager internal openImpl;
    LPManagerFactory internal fac;

    bytes32 internal constant ORACLE_SET = keccak256("PriceOracleSet(address)");

    function setUp() public override {
        super.setUp();
        oracle = new MockPriceOracle();
        oracle.setMode(MockPriceOracle.Mode.Pass);
        volImpl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        openImpl = new OpenVolatileLPManager(IPoolManager(address(poolManager)), treasury);
        address[] memory impls = new address[](3);
        impls[0] = address(impl);
        impls[1] = address(volImpl);
        impls[2] = address(openImpl);
        fac = new LPManagerFactory(address(this), impls);
    }

    function _stable(address o) internal returns (StableLPManager m) {
        StableLPManager.InitParams memory p = _initParams(owner);
        p.oracle = o;
        m = FactoryHelper.cloneStable(fac, address(impl), p);
    }

    function _vol(address implementation, address o) internal returns (VolatileLPManager m) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = poolKeys[0];
        m = FactoryHelper.cloneVolatile(
            fac,
            implementation,
            VolatileLPManager.InitParams({owner: owner, name: "", descriptor: address(0), oracle: o, pools: keys})
        );
    }

    function _oracleSetEvents(address emitter) internal returns (uint256 n, address last) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length == 2 && logs[i].topics[0] == ORACLE_SET) {
                ++n;
                last = address(uint160(uint256(logs[i].topics[1])));
            }
        }
    }

    // ────────── wiring ──────────

    function test_stable_initWithOracle_setsItAndEmits() public {
        vm.recordLogs();
        StableLPManager m = _stable(address(oracle));
        assertEq(m.priceOracle(), address(oracle));
        (uint256 n, address last) = _oracleSetEvents(address(m));
        assertEq(n, 1, "one PriceOracleSet at init");
        assertEq(last, address(oracle));
    }

    function test_stable_initWithoutOracle_noneAndNoEvent() public {
        vm.recordLogs();
        StableLPManager m = _stable(address(0));
        assertEq(m.priceOracle(), address(0));
        (uint256 n,) = _oracleSetEvents(address(m));
        assertEq(n, 0, "no event when nothing is wired");
    }

    function test_volatileAndOpen_initWithOracle() public {
        vm.recordLogs();
        VolatileLPManager v = _vol(address(volImpl), address(oracle));
        (uint256 nv,) = _oracleSetEvents(address(v)); // getRecordedLogs drains the buffer
        vm.recordLogs();
        VolatileLPManager o = _vol(address(openImpl), address(oracle));
        (uint256 no,) = _oracleSetEvents(address(o));
        assertEq(v.priceOracle(), address(oracle), "volatile");
        assertEq(o.priceOracle(), address(oracle), "open");
        assertEq(nv, 1, "volatile emits once");
        assertEq(no, 1, "open emits once");
        assertEq(_vol(address(volImpl), address(0)).priceOracle(), address(0), "zero stays zero");
    }

    // ────────── what it buys: operators work from the first block ──────────

    function test_stable_operatorSwap_worksWithInitOracle() public {
        StableLPManager m = _stable(address(oracle));
        _fund(m);
        vm.prank(owner);
        m.setOperator(bot, true);
        vm.prank(bot);
        m.allocate(_allocateParams(FUND)); // pre-swaps + adds, all oracle-gated for an operator
        assertGt(m.openPositionCount(), 0);
    }

    function test_stable_operatorSwap_failClosedWithoutOracle() public {
        StableLPManager m = _stable(address(0));
        _fund(m);
        vm.prank(owner);
        m.setOperator(bot, true);
        vm.prank(bot);
        vm.expectRevert(BaseLPManager.OperatorSwapGuardRequired.selector);
        m.allocate(_allocateParams(FUND));
    }

    function test_initOracle_ownerCanReplaceAndClear() public {
        StableLPManager m = _stable(address(oracle));
        address other = address(new MockPriceOracle());
        vm.startPrank(owner);
        m.setPriceOracle(other);
        assertEq(m.priceOracle(), other);
        m.setPriceOracle(address(0));
        assertEq(m.priceOracle(), address(0));
        vm.stopPrank();
        vm.expectRevert();
        m.setPriceOracle(address(oracle)); // not the owner
    }

    // ────────── ABI: the init selector changed with the struct ──────────

    function test_initializeSelectors_includeOracleField() public pure {
        assertEq(
            StableLPManager.initialize.selector,
            bytes4(
                keccak256(
                    "initialize((address,bytes32,address,address,((address,address,uint24,int24,address),int24,int24)[]))"
                )
            )
        );
        assertEq(
            VolatileLPManager.initialize.selector,
            bytes4(keccak256("initialize((address,bytes32,address,address,(address,address,uint24,int24,address)[]))"))
        );
    }

    function _fund(StableLPManager m) internal {
        MockERC20(Currency.unwrap(USDT)).mint(address(m), FUND);
    }
}
