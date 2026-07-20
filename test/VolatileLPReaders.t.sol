// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {UniLens} from "../src/UniLens.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {MockERC20} from "./helpers/Mocks.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Compatibility proof that the two product-agnostic readers — {UniLens} and
/// {WalletPositionDescriptor} — work against a REAL {VolatileLPManager} (not the NFT/ops harness the
/// existing reader suites use). The refactor made both products thin subclasses of {BaseLPManager}, so
/// the read surface (`positionOf` / `openSalts` / `openPositionCount` + the `BaseLPManager` config
/// getters) is inherited unchanged. This suite pins that: `positions()` matches `positionOf` +
/// `PositionState.value`, `managerInfo()` returns correct config despite its `StableLPManager` cast
/// (the members it touches all live on `BaseLPManager`), and `tokenURI(1)` renders end-to-end.
///
/// Two configured pools sharing a middle currency (t0/t1 and t1/t2) also exercise the managed-currency
/// union for a volatile manager: the dedup'd set must be {t0, t1, t2}.
contract VolatileLPReadersTest is Test {
    using stdJson for string;
    using StateLibrary for IPoolManager;

    PoolManager internal poolManager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    VolatileLPManager internal mgr;
    UniLens internal lens;
    WalletPositionDescriptor internal descriptor;

    Currency internal t0;
    Currency internal t1;
    Currency internal t2;
    PoolKey internal keyA; // (t0, t1)
    PoolKey internal keyB; // (t1, t2)
    PoolId internal poolA;
    PoolId internal poolB;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xFEE5);
    address internal lp = address(0xABCD);
    address internal trader = address(0x7EA4E5);

    int24 internal constant SPACING = 60;
    uint24 internal constant FEE = 3000;
    uint256 internal constant FUND = 1_000e18;

    string internal constant JSON_PREFIX = "data:application/json;base64,";

    function setUp() public {
        poolManager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Three sorted tokens ⇒ two hookless pools sharing the middle currency.
        (t0, t1, t2) = _sort3(
            Currency.wrap(address(new MockERC20())),
            Currency.wrap(address(new MockERC20())),
            Currency.wrap(address(new MockERC20()))
        );
        keyA = _pool(t0, t1);
        keyB = _pool(t1, t2);
        poolA = keyA.toId();
        poolB = keyB.toId();
        _initAndSeed(keyA);
        _initAndSeed(keyB);

        VolatileLPManager impl = new VolatileLPManager(IPoolManager(address(poolManager)), treasury);
        mgr = VolatileLPManager(payable(Clones.clone(address(impl))));

        PoolKey[] memory cfgs = new PoolKey[](2);
        cfgs[0] = keyA;
        cfgs[1] = keyB;
        mgr.initialize(
            VolatileLPManager.InitParams({owner: owner, name: bytes32("Vol"), descriptor: address(0), pools: cfgs})
        );

        // Fund the manager with all three managed currencies so allocate/idle balances are meaningful.
        MockERC20(Currency.unwrap(t0)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(t1)).mint(address(mgr), FUND);
        MockERC20(Currency.unwrap(t2)).mint(address(mgr), FUND);

        lens = new UniLens();
        descriptor = new WalletPositionDescriptor();
        vm.prank(owner);
        mgr.setPositionDescriptor(address(descriptor));
    }

    // ────────── UniLens.positions / position ──────────

    function test_positions_matchPositionStateAndCarryFees() public {
        // Two positions in pool A (multi-position per pool) + one in pool B.
        vm.startPrank(owner);
        mgr.allocate(_one(poolA, _leg(bytes32(uint256(1)), -SPACING, SPACING, 200e18)));
        mgr.allocate(_one(poolA, _leg(bytes32(uint256(2)), -2 * SPACING, 2 * SPACING, 200e18)));
        mgr.allocate(_one(poolB, _leg(bytes32(uint256(3)), -SPACING, SPACING, 200e18)));
        vm.stopPrank();

        // Round-trip trades in pool A so its in-range positions accrue fees on both sides.
        _trade(keyA, true, -1e18);
        _trade(keyA, false, -1e18);

        UniLens.PositionView[] memory views = lens.positions(address(mgr));
        assertEq(views.length, mgr.openPositionCount(), "count == openPositionCount");
        assertEq(views.length, 3, "three positions");

        bool sawFees;
        for (uint256 i = 0; i < views.length; ++i) {
            UniLens.PositionView memory v = views[i];
            V4PositionManager.Position memory p = mgr.positionOf(v.salt);
            (uint160 sqrtP,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), p.key.toId());
            (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
                PositionState.value(IPoolManager(address(poolManager)), address(mgr), v.salt, p);

            // Every field the lens returns must equal the underlying manager/library state.
            assertEq(v.liquidity, p.liquidity, "liquidity");
            assertEq(v.tickLower, p.tickLower, "tickLower");
            assertEq(v.tickUpper, p.tickUpper, "tickUpper");
            assertEq(Currency.unwrap(v.key.currency0), Currency.unwrap(p.key.currency0), "currency0");
            assertEq(Currency.unwrap(v.key.currency1), Currency.unwrap(p.key.currency1), "currency1");
            assertEq(v.sqrtPriceX96, sqrtP, "sqrtPriceX96");
            assertEq(v.amount0, a0, "amount0");
            assertEq(v.amount1, a1, "amount1");
            assertEq(v.fees0, f0, "fees0");
            assertEq(v.fees1, f1, "fees1");
            if (f0 > 0 || f1 > 0) sawFees = true;
        }
        assertTrue(sawFees, "fees carried through for the traded pool");
    }

    function test_position_single() public {
        bytes32 s = bytes32(uint256(7));
        vm.prank(owner);
        mgr.allocate(_one(poolA, _leg(s, -SPACING, SPACING, 100e18)));

        UniLens.PositionView memory v = lens.position(address(mgr), s);
        assertEq(v.salt, s, "salt");
        assertEq(v.liquidity, mgr.positionOf(s).liquidity, "liquidity matches");
        assertGt(v.amount0, 0, "amount0");
        assertGt(v.amount1, 0, "amount1");
        assertGt(uint256(v.sqrtPriceX96), 0, "price set");
    }

    // ────────── UniLens.managerInfo (StableLPManager cast, but all members live on BaseLPManager) ──────────

    function test_managerInfo_volatile() public view {
        UniLens.ManagerView memory info = lens.managerInfo(address(mgr));

        assertEq(info.owner, owner, "owner");
        assertEq(info.treasury, treasury, "treasury");
        assertEq(uint256(info.protocolFeeBps), 1000, "protocol fee bps (10%)");

        // Two configured pools sharing t1 ⇒ deduped managed-currency union is {t0, t1, t2}.
        assertEq(info.pools.length, 2, "two configured pools");
        assertEq(info.managedStables.length, 3, "managed-currency union deduped");
        assertEq(info.idleBalances.length, info.managedStables.length, "idle balances aligned");

        // Fresh manager (no allocate) ⇒ each managed currency's idle balance == FUND funded above.
        bool saw0;
        bool saw1;
        bool saw2;
        for (uint256 i = 0; i < info.managedStables.length; ++i) {
            address c = Currency.unwrap(info.managedStables[i]);
            assertEq(info.idleBalances[i], FUND, "idle == FUND");
            if (c == Currency.unwrap(t0)) saw0 = true;
            if (c == Currency.unwrap(t1)) saw1 = true;
            if (c == Currency.unwrap(t2)) saw2 = true;
        }
        assertTrue(saw0 && saw1 && saw2, "union == {t0, t1, t2}");
    }

    // ────────── WalletPositionDescriptor.tokenURI end-to-end (mgr → descriptor) ──────────

    function test_tokenURI_emptyPortfolio_isValidDataUri() public view {
        string memory uri = mgr.tokenURI(1);
        assertTrue(_startsWith(uri, JSON_PREFIX), "data:application/json prefix");
    }

    function test_tokenURI_withPositions_ffiDecode() public {
        vm.startPrank(owner);
        mgr.allocate(_one(poolA, _leg(bytes32(uint256(1)), -SPACING, SPACING, 200e18)));
        mgr.allocate(_one(poolB, _leg(bytes32(uint256(2)), -2 * SPACING, 2 * SPACING, 200e18)));
        vm.stopPrank();
        _trade(keyA, true, -1e18);
        _trade(keyA, false, -1e18);

        string memory uri = mgr.tokenURI(1);
        assertTrue(_startsWith(uri, JSON_PREFIX), "prefix");

        string memory json = _decodeJson(uri);
        // Volatile NFT name is "Vol"; the descriptor is product-agnostic so the rendered name carries it.
        assertTrue(_contains(json.readString(".name"), "Vol"), "name carries the manager name");
        assertEq(json.readString(".attributes[0].value"), "2", "open position count");

        // First salt opened == pool A at [-SPACING, SPACING]; assert the descriptor read it correctly.
        assertEq(json.readString(".positions[0].currency0"), Strings.toHexString(Currency.unwrap(t0)), "currency0");
        assertEq(json.readString(".positions[0].currency1"), Strings.toHexString(Currency.unwrap(t1)), "currency1");
        assertEq(json.readInt(".positions[0].tickLower"), int256(int24(-SPACING)), "tickLower");
        assertEq(json.readInt(".positions[0].tickUpper"), int256(int24(SPACING)), "tickUpper");
        assertGt(vm.parseUint(json.readString(".positions[0].amount0")), 0, "amount0");
        assertGt(vm.parseUint(json.readString(".positions[0].fees0")), 0, "fees0 after swaps");

        // Second position (pool B) rendered too.
        assertEq(json.readInt(".positions[1].tickLower"), int256(int24(-2 * SPACING)), "pos1 tickLower");
    }

    // ────────── setup helpers ──────────

    function _sort3(Currency a, Currency b, Currency c) internal pure returns (Currency, Currency, Currency) {
        (a, b) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        (b, c) = Currency.unwrap(b) < Currency.unwrap(c) ? (b, c) : (c, b);
        (a, b) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return (a, b, c);
    }

    function _pool(Currency ca, Currency cb) internal pure returns (PoolKey memory) {
        return PoolKey({currency0: ca, currency1: cb, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
    }

    function _initAndSeed(PoolKey memory key) internal {
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0)); // 1:1
        uint256 amt = 2_000_000e18;
        MockERC20(Currency.unwrap(key.currency0)).mint(lp, amt);
        MockERC20(Currency.unwrap(key.currency1)).mint(lp, amt);
        vm.startPrank(lp);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: int256(1_000_000e18), salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    function _leg(bytes32 salt, int24 tl, int24 tu, uint256 amt)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg memory)
    {
        return VolatileLPManager.VolatileAllocLeg({
            poolId: PoolId.wrap(bytes32(0)), // set by _one
            salt: salt,
            tickLower: tl,
            tickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            amount0Desired: amt,
            amount1Desired: amt,
            minLiquidity: 0
        });
    }

    function _one(PoolId poolId, VolatileLPManager.VolatileAllocLeg memory l)
        internal
        pure
        returns (VolatileLPManager.VolatileAllocLeg[] memory legs)
    {
        l.poolId = poolId;
        legs = new VolatileLPManager.VolatileAllocLeg[](1);
        legs[0] = l;
    }

    function _trade(PoolKey memory key, bool zeroForOne, int256 amt) internal {
        MockERC20(Currency.unwrap(key.currency0)).mint(trader, 100e18);
        MockERC20(Currency.unwrap(key.currency1)).mint(trader, 100e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ────────── string / ffi helpers (mirrors WalletPositionDescriptor.t.sol) ──────────

    function _decodeJson(string memory dataUri) internal returns (string memory) {
        string memory b64 = _afterPrefix(dataUri, JSON_PREFIX);
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat("printf '%s' '", b64, "' | base64 -d");
        return string(vm.ffi(cmd));
    }

    function _afterPrefix(string memory s, string memory p) internal pure returns (string memory) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(p);
        bytes memory out = new bytes(sb.length - pb.length);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = sb[pb.length + i];
        }
        return string(out);
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(p);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; ++i) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory ndl = bytes(needle);
        if (ndl.length == 0 || h.length < ndl.length) return false;
        for (uint256 i = 0; i <= h.length - ndl.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < ndl.length; ++j) {
                if (h[i + j] != ndl[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
