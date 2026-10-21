// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {NFTPositionHarness} from "./helpers/NFTPositionHarness.sol";
import {MetaNFTHarness} from "./helpers/MetaNFTHarness.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";
import {PositionState} from "../src/lib/PositionState.sol";
import {V4PositionManager} from "../src/abstract/V4PositionManager.sol";
import {MockERC20, MockMetaERC20, HostileMetaERC20, MockV3Pool} from "./helpers/Mocks.sol";
import {DescriptorLibWrapper} from "./helpers/DescriptorLibWrapper.sol";
import {V4WalletTestBase} from "./helpers/V4WalletTestBase.sol";

contract WalletPositionDescriptorTest is V4WalletTestBase {
    using stdJson for string;

    WalletPositionDescriptor internal descriptor;
    MetaNFTHarness internal mw; // == wallet, typed
    PoolSwapTest internal swapRouter;
    DescriptorLibWrapper internal fmt;
    address internal trader = address(0xCAFE);

    string internal constant JSON_PREFIX = "data:application/json;base64,";
    uint8 internal constant OWN_POOL = 1;
    uint8 internal constant UNPRICED = 2;

    event MetadataUpdate(uint256 _tokenId);

    function setUp() public override {
        super.setUp();
        // Replace the base wallet with the metadata-configurable harness (same surface).
        vm.prank(owner);
        mw = new MetaNFTHarness(IPoolManager(address(poolManager)));
        wallet = mw;
        MockERC20(Currency.unwrap(currency0)).mint(address(wallet), 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(wallet), 1_000e18);

        descriptor = _newDescriptor(address(0));
        vm.prank(owner);
        wallet.setPositionDescriptor(address(descriptor));

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        fmt = new DescriptorLibWrapper();
    }

    function _newDescriptor(address weth) internal returns (WalletPositionDescriptor) {
        return new WalletPositionDescriptor(
            IPoolManager(address(poolManager)),
            address(this),
            weth,
            "ETH",
            new address[](0),
            new WalletPositionDescriptor.RefInit[](0)
        );
    }

    // ────────── fixtures ──────────

    function _tok(string memory sym, uint256 dec) internal returns (MockMetaERC20 t) {
        t = new MockMetaERC20(sym, dec);
        t.mint(address(wallet), 1e40);
        t.mint(trader, 1e40);
        vm.prank(trader);
        t.approve(address(swapRouter), type(uint256).max);
    }

    /// @dev A hookless pool over (a, b) at `tick` (price of currency1 in currency0, raw units).
    function _pool(address a, address b, uint24 fee, int24 spacing, int24 tick) internal returns (PoolKey memory k) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(k, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @dev Tick (rounded to `spacing`) at which one whole `base` buys `usdPerBase` whole `quote`.
    function _tickFor(address base, uint256 baseDec, address quote, uint256 quoteDec, uint256 usdPerBase)
        internal
        pure
        returns (int24)
    {
        // raw price quote/base = usd * 10^qd / 10^bd; tick = log_1.0001(price) (approximated by bisection)
        uint256 num = usdPerBase * 10 ** quoteDec;
        uint256 den = 10 ** baseDec;
        bool baseIs0 = base < quote;
        if (!baseIs0) (num, den) = (den, num);
        int24 lo = -887_000;
        int24 hi = 887_000;
        while (hi - lo > 1) {
            int24 mid = (lo + hi) / 2;
            uint160 sp = TickMath.getSqrtPriceAtTick(mid);
            // price(mid) = sp^2 / 2^192  vs  num/den
            if (FullMath.mulDiv(FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96), den, 1 << 96) < num) lo = mid;
            else hi = mid;
        }
        return (lo / 10) * 10;
    }

    function _openIn(PoolKey memory k, int24 tl, int24 tu, uint128 liq, bytes32 salt) internal {
        vm.prank(owner);
        wallet.openPosition(k, tl, tu, liq, salt, 0, type(uint128).max, type(uint128).max);
    }

    /// @dev A position straddling the current tick of `k` (±`w` spacings).
    function _openAround(PoolKey memory k, int24 tick, uint128 liq, bytes32 salt) internal {
        int24 s = k.tickSpacing;
        int24 base = (tick / s) * s;
        _openIn(k, base - 20 * s, base + 20 * s, liq, salt);
    }

    function _swapIn(PoolKey memory k, bool zeroForOne, int256 amt) internal {
        vm.prank(trader);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sp(PoolKey memory k) internal view returns (uint160 sp) {
        (sp,,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), k.toId());
    }

    /// @dev Independent conversion (different 512-bit split than the descriptor) of `amt` of the leg
    /// `tokenIs0` into the other leg at `sp`.
    function _conv(uint256 amt, uint160 sp, bool tokenIs0) internal pure returns (uint256) {
        if (tokenIs0) return FullMath.mulDiv(FullMath.mulDiv(amt, sp, 1 << 64), sp, 1 << 128);
        return FullMath.mulDiv(FullMath.mulDiv(amt, 1 << 128, sp), 1 << 64, sp);
    }

    function _row(bytes32 salt) internal view returns (WalletPositionDescriptor.Row memory) {
        return descriptor.positionValue(address(wallet), salt);
    }

    /// @dev A stable/volatile pair with the stable on the requested side; returns (key, stable, vol).
    function _stablePair(bool stableIs0, uint256 stableDec, uint256 volDec, uint256 usdPerVol)
        internal
        returns (PoolKey memory k, MockMetaERC20 s, MockMetaERC20 v, int24 tick)
    {
        s = _tok("USDC", stableDec);
        v = _tok("WBTC", volDec);
        if ((address(s) < address(v)) != stableIs0) {
            // re-roll the volatile token until the ordering matches
            for (uint256 i = 0; i < 8 && (address(s) < address(v)) != stableIs0; ++i) {
                v = _tok("WBTC", volDec);
            }
        }
        require((address(s) < address(v)) == stableIs0, "ordering");
        tick = _tickFor(address(v), volDec, address(s), stableDec, usdPerVol);
        k = _pool(address(s), address(v), 500, 10, tick);
    }

    // ────────── tokenURI basics ──────────

    function test_tokenURI_noDescriptor_returnsEmpty() public {
        NFTPositionHarness bare = new NFTPositionHarness(IPoolManager(address(poolManager)));
        assertEq(bytes(bare.tokenURI(1)).length, 0, "no descriptor returns empty");
    }

    function test_tokenURI_emptyPortfolio_isValidDataUri() public {
        string memory uri = wallet.tokenURI(1);
        assertTrue(_startsWith(uri, JSON_PREFIX), "data:application/json prefix");
        string memory json = _decodeJson(uri);
        assertEq(_attr(json, "Open Positions"), "0", "no positions");
        assertEq(_attr(json, "Liquidity (USD)"), "0.00", "zero liquidity");
        assertEq(_attr(json, "Unclaimed Fees (USD)"), "0.00", "zero fees");
        assertEq(_attr(json, "Pricing"), "reference pools", "nothing to flag");
    }

    function test_tokenURI_unmintedId_reverts() public {
        vm.expectRevert();
        wallet.tokenURI(2); // only TOKEN_ID = 1 exists
    }

    /// @notice ffi-decode the JSON and check the per-position fields against on-chain state.
    function test_tokenURI_ffiDecode_contentMatchesState() public {
        _open(bytes32(uint256(1)), -SPACING, SPACING);
        _open(bytes32(uint256(2)), -2 * SPACING, 2 * SPACING);
        _swap(true, -1e15);
        _swap(false, -1e15);

        string memory json = _decodeJson(wallet.tokenURI(1));

        assertEq(json.readString(".name"), "Envelop NFT Position #1", "name");
        assertEq(_attr(json, "Open Positions"), "2", "open position count");
        assertEq(json.readString(".positions[0].salt"), Strings.toHexString(uint256(1), 32), "salt");
        assertEq(
            json.readString(".positions[0].currency0"), Strings.toHexString(Currency.unwrap(currency0)), "currency0"
        );
        assertEq(
            json.readString(".positions[0].currency1"), Strings.toHexString(Currency.unwrap(currency1)), "currency1"
        );
        assertEq(json.readInt(".positions[0].tickLower"), int256(int24(-SPACING)), "tickLower");
        assertEq(json.readInt(".positions[0].tickUpper"), int256(int24(SPACING)), "tickUpper");
        assertGt(vm.parseUint(json.readString(".positions[0].amount0")), 0, "amount0");
        assertGt(vm.parseUint(json.readString(".positions[0].fees0")), 0, "fees0 after swaps");
        assertGt(vm.parseUint(json.readString(".positions[0].fees1")), 0, "fees1 after swaps");
        assertEq(json.readInt(".positions[1].tickLower"), int256(int24(-2 * SPACING)), "pos1 tickLower");
    }

    // ────────── bug 1: no stable, no reference ⇒ unpriced, never $1/token ──────────

    function test_noStable_noReference_unpriced() public {
        _open(bytes32(uint256(1)), -SPACING, SPACING);

        WalletPositionDescriptor.Row memory r = _row(bytes32(uint256(1)));
        assertEq(r.flags & UNPRICED, UNPRICED, "unpriced");
        assertEq(r.principalUsd, 0, "no USD invented");

        string memory json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Pricing"), "unpriced", "pricing attr");
        assertFalse(_hasAttr(json, "Liquidity (USD)"), "no liquidity attribute");
        assertFalse(_hasAttr(json, "Unclaimed Fees (USD)"), "no fees attribute");
        assertFalse(vm.keyExistsJson(json, ".positions[0].liquidityUsd"), "no per-position liquidity");
        assertFalse(vm.keyExistsJson(json, ".positions[0].feesUsd"), "no per-position fees");
        string memory svg = _decodeImage(json);
        assertTrue(_contains(svg, ">unpriced<"), "card says unpriced");
        assertFalse(_contains(svg, "$"), "no dollar figure anywhere");
    }

    // ────────── bug 2: reference pool beats the manager's own pool; own-pool fallback is flagged ──────────

    function test_stableLeg1_noReference_pricedByOwnPool_flagged() public {
        _ownPoolCase(false);
    }

    function test_stableLeg0_noReference_pricedByOwnPool_flagged() public {
        _ownPoolCase(true);
    }

    function _ownPoolCase(bool stableIs0) internal {
        (PoolKey memory k, MockMetaERC20 s,, int24 tick) = _stablePair(stableIs0, 6, 8, 60_000);
        descriptor.setStable(address(s), true);
        bytes32 salt = bytes32(uint256(0xA1));
        _openAround(k, tick, 1e12, salt);

        WalletPositionDescriptor.Row memory r = _row(salt);
        assertEq(r.flags, OWN_POOL, "own-pool flag");
        uint160 sp = _sp(k);
        // stable leg at $1, volatile leg converted through the own pool
        (uint256 aS, uint256 aV) = stableIs0 ? (r.a0, r.a1) : (r.a1, r.a0);
        assertGt(aV, 0, "volatile leg held");
        uint256 expected = ((aS + _conv(aV, sp, !stableIs0)) * 1e18) / 1e6;
        assertApproxEqRel(r.principalUsd, expected, 1e9, "own-pool valuation");
        // sanity: 1 WBTC (1e8) at this pool ≈ $60,000 (within one tick spacing)
        assertApproxEqRel(_conv(1e8, sp, !stableIs0), 60_000e6, 2e15, "price ~ $60k");

        string memory json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Pricing"), "own pool", "flag in attributes");
        assertTrue(_contains(_decodeImage(json), "priced by own pool"), "flag on card");
        assertEq(_attr(json, "Liquidity (USD)"), _usd2(r.principalUsd), "liquidity attr");
        assertEq(_attr(json, "Unclaimed Fees (USD)"), _usd2(r.feeUsd), "fees attr");
    }

    function test_referenceV4_beatsSkewedOwnPool() public {
        (PoolKey memory own, MockMetaERC20 s, MockMetaERC20 v,) = _stablePair(false, 6, 8, 120_000); // skewed 2x
        int24 fair = _tickFor(address(v), 8, address(s), 6, 60_000);
        PoolKey memory ref = _pool(address(s), address(v), 3000, 60, fair);
        descriptor.setStable(address(s), true);
        descriptor.setReference(address(v), address(0), ref);

        bytes32 salt = bytes32(uint256(0xB1));
        (, int24 ownTick,,) = StateLibrary.getSlot0(IPoolManager(address(poolManager)), own.toId());
        _openAround(own, ownTick, 1e12, salt);

        WalletPositionDescriptor.Row memory r = _row(salt);
        assertEq(r.flags, 0, "reference, not own pool");
        bool vIs0 = address(v) < address(s);
        assertApproxEqRel(r.principalUsd, _usd6Via(r, vIs0, _sp(ref)), 1e9, "reference price used");
        assertGt(_usd6Via(r, vIs0, _sp(own)), (r.principalUsd * 13) / 10, "the skewed own pool would inflate it");

        string memory json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Pricing"), "reference pools", "no flag");
    }

    /// @notice Two hops: TOKEN → (v3) → WETH → (v4) → USDC; the pair itself has no stable.
    function test_referenceTwoHop_v3ThenV4_noStableInPair() public {
        MockMetaERC20 s = _tok("USDC", 6);
        MockMetaERC20 w = _tok("WETH", 18);
        MockMetaERC20 t = _tok("ARB", 18);
        // WETH = $2,500 via a v4 reference; ARB = 0.0001 WETH (= $0.25) via a v3 reference.
        PoolKey memory wRef = _pool(address(w), address(s), 500, 10, _tickFor(address(w), 18, address(s), 6, 2500));
        int24 arbTick = _tickFor(address(t), 18, address(w), 18, 1) - _signed(address(t) < address(w), 92_100); // ÷1e4
        MockV3Pool tRef = new MockV3Pool(address(t), address(w), TickMath.getSqrtPriceAtTick(arbTick));
        descriptor.setStable(address(s), true);
        descriptor.setReference(address(w), address(0), wRef);
        PoolKey memory none;
        descriptor.setReference(address(t), address(tRef), none);

        // The manager's own pool is ARB/WETH at the same price.
        PoolKey memory own = _pool(address(t), address(w), 3000, 60, arbTick);
        bytes32 salt = bytes32(uint256(0xC1));
        _openAround(own, arbTick, 1e20, salt);

        _checkTwoHop(_row(salt), address(t) < address(w), tRef.sqrtPriceX96(), _sp(wRef), address(w) < address(s));
    }

    function _checkTwoHop(WalletPositionDescriptor.Row memory r, bool tIs0, uint160 spT, uint160 spW, bool wIs0)
        internal
        pure
    {
        assertEq(r.flags, 0, "both legs via references");
        (uint256 aT, uint256 aW) = tIs0 ? (r.a0, r.a1) : (r.a1, r.a0);
        uint256 expected = (_conv(aW + _conv(aT, spT, tIs0), spW, wIs0) * 1e18) / 1e6;
        assertApproxEqAbs(r.principalUsd, expected, 3e12, "two-hop valuation (legs floor to 1 raw USDC each)");
        // sanity: 1 ARB ~ $0.25
        assertApproxEqRel(_conv(_conv(1e18, spT, tIs0), spW, wIs0), 0.25e6, 2e15, "ARB ~ $0.25");
    }

    /// @dev Independent USD of a (6-dec stable, volatile) row with the volatile leg converted at `sp`.
    function _usd6Via(WalletPositionDescriptor.Row memory r, bool vIs0, uint160 sp) internal pure returns (uint256) {
        (uint256 aS, uint256 aV) = vIs0 ? (r.a1, r.a0) : (r.a0, r.a1);
        return ((aS + _conv(aV, sp, vIs0)) * 1e18) / 1e6;
    }

    function _signed(bool positive, int24 x) internal pure returns (int24) {
        return positive ? x : -x;
    }

    /// @notice WETH and native share one registry entry: a reference set for native prices a WETH leg.
    function test_reference_nativeAliasesWeth() public {
        MockMetaERC20 s = _tok("USDC", 6);
        MockMetaERC20 w = _tok("WETH", 18);
        MockMetaERC20 t = _tok("ARB", 18);
        descriptor = _newDescriptor(address(w));
        vm.prank(owner);
        wallet.setPositionDescriptor(address(descriptor));
        descriptor.setStable(address(s), true);
        MockV3Pool wRef = new MockV3Pool(
            address(w), address(s), TickMath.getSqrtPriceAtTick(_tickFor(address(w), 18, address(s), 6, 2500))
        );
        PoolKey memory none;
        descriptor.setReference(address(0), address(wRef), none); // keyed by native, pool holds WETH
        (,, address quote,) = descriptor.references(address(0));
        assertEq(quote, address(s), "quote resolved");

        int24 tick = _tickFor(address(t), 18, address(w), 18, 1) - _signed(address(t) < address(w), 92_100);
        PoolKey memory own = _pool(address(t), address(w), 3000, 60, tick);
        bytes32 salt = bytes32(uint256(0xD1));
        _openAround(own, tick, 1e20, salt);
        WalletPositionDescriptor.Row memory r = _row(salt);
        // ARB has no reference and its partner is not a stable ⇒ the ARB leg is unpriced, but the WETH
        // leg alone is priced through the native entry (checked via the fee-free principal split).
        assertEq(r.flags & UNPRICED, UNPRICED, "ARB leg unpriced");
        descriptor.setReference(
            address(t), address(new MockV3Pool(address(t), address(w), TickMath.getSqrtPriceAtTick(tick))), none
        );
        r = _row(salt);
        assertEq(r.flags, 0, "priced once ARB has a reference");
        assertGt(r.principalUsd, 0, "value");
    }

    // ────────── bug 3/4 + task_059: fees net of the protocol cut; two sums, no APR ──────────

    function test_fees_netOfProtocolCut() public {
        bytes32 salt = bytes32(uint256(1));
        _open(salt, -SPACING, SPACING);
        _swap(true, -1e16);
        _swap(false, -1e16);
        V4PositionManager.Position memory p = wallet.positionOf(salt);
        (,, uint256 g0, uint256 g1) = PositionState.value(IPoolManager(address(poolManager)), address(wallet), salt, p);
        assertGt(g0, 0, "gross fees");
        WalletPositionDescriptor.Row memory r = _row(salt);
        assertEq(r.f0, g0 - (g0 * 1000 + 9999) / 10_000, "fees0 net");
        assertEq(r.f1, g1 - (g1 * 1000 + 9999) / 10_000, "fees1 net");
    }

    /// @notice task_059: the card shows Liquidity (principal) and Unclaimed fees (net) as separate sums and
    /// no APR; a claim zeroes the fees and leaves the liquidity where it was.
    function test_twoSums_liquidityAndUnclaimedFees_noApr() public {
        (PoolKey memory k, MockMetaERC20 s,, int24 tick) = _stablePair(false, 18, 18, 1);
        descriptor.setStable(address(s), true);
        bytes32 salt = bytes32(uint256(0xE1));
        _openAround(k, tick, 1e21, salt);
        _swapIn(k, true, -1e19);
        _swapIn(k, false, -1e19);
        vm.warp(block.timestamp + 30 days);

        WalletPositionDescriptor.Row memory r = _row(salt);
        assertGt(r.feeUsd, 0, "fees accrued");
        string memory json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Liquidity (USD)"), _usd2(r.principalUsd), "liquidity = principal only");
        assertEq(_attr(json, "Unclaimed Fees (USD)"), _usd2(r.feeUsd), "fees net");
        assertEq(json.readString(".positions[0].liquidityUsd"), _usd2(r.principalUsd), "per-position liquidity");
        assertEq(json.readString(".positions[0].feesUsd"), _usd2(r.feeUsd), "per-position fees");
        assertFalse(_hasAttr(json, "Est. APR (bps)"), "no APR attribute");
        string memory svg = _decodeImage(json);
        assertTrue(_contains(svg, ">Liquidity<"), "liquidity label");
        assertTrue(_contains(svg, "Unclaimed fees: $"), "fees line");
        assertFalse(_contains(svg, "APR"), "no APR on the card");

        vm.prank(owner);
        wallet.pokePosition(salt); // claim: fee counters reset
        json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Unclaimed Fees (USD)"), "0.00", "claimed");
        assertEq(_attr(json, "Liquidity (USD)"), _usd2(r.principalUsd), "liquidity untouched by the claim");
    }

    // ────────── bug 5/6: escaping ──────────

    function test_escaping_nameAndSymbols() public {
        mw.setName(string(abi.encodePacked('A"<&>', "'\\", hex"c3", "Z")));
        MockMetaERC20 s = _tok("U<b>&\"", 6);
        MockMetaERC20 v = _tok("X'</text>", 18);
        PoolKey memory k = _pool(address(s), address(v), 500, 10, 0);
        _openIn(k, -100, 100, 1e12, bytes32(uint256(0xF1)));

        string memory json = _decodeJson(wallet.tokenURI(1)); // must still be valid JSON
        assertEq(json.readString(".name"), string(abi.encodePacked('A"<&>', "'\\?Z #1")), "JSON-escaped name");
        string memory svg = _decodeImage(json);
        assertTrue(_contains(svg, "A&quot;&lt;&amp;&gt;&apos;\\?Z"), "XML-escaped name");
        assertTrue(_contains(svg, "U&lt;b&gt;&amp;&quot;"), "XML-escaped symbol");
        assertFalse(_contains(svg, "</text>'"), "no injected markup");
        assertFalse(_contains(svg, "<b>"), "no injected tag");
    }

    /// @notice task_063: a 32-byte name and 12-byte symbols stay inside the 320 px card.
    function test_cardLayout_longNameSmallerFont_symbolsCappedForChips() public {
        mw.setName("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW");
        MockMetaERC20 s = _tok("USDC", 18);
        descriptor.setStable(address(s), true);
        MockMetaERC20 v = _tok("SolvBTC.BBNX", 18);
        _openIn(_pool(address(s), address(v), 500, 10, 0), -1000, 1000, 1e12, bytes32(uint256(0x63)));

        string memory svg = _decodeImage(_decodeJson(wallet.tokenURI(1)));
        assertTrue(_contains(svg, 'font-size="13">WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW<'), "long name at 13 px");
        assertTrue(_contains(svg, ">SolvBTC.<"), "chip label capped at 8 bytes");
        assertFalse(_contains(svg, "SolvBTC.B"), "no overflow into the next chip");

        mw.setName("Short");
        svg = _decodeImage(_decodeJson(wallet.tokenURI(1)));
        assertTrue(_contains(svg, 'font-size="16">Short<'), "short name keeps 16 px");
    }

    function test_clean_utf8AndCaps() public view {
        // multi-byte sequences survive; a sequence crossing the cap is dropped whole
        assertEq(fmt.clean(bytes(unicode"héllo"), 32, false), unicode"héllo", "2-byte kept");
        assertEq(fmt.clean(bytes(unicode"aé"), 2, false), "a", "never split a code point");
        assertEq(fmt.clean(bytes(unicode"€"), 3, true), unicode"€", "3-byte kept");
        assertEq(fmt.clean(bytes(unicode"🦄x"), 32, true), unicode"🦄x", "4-byte kept");
        // malformed: stray continuation, truncated lead, overlong, surrogate, control
        assertEq(fmt.clean(hex"80", 8, true), "?", "stray continuation");
        assertEq(fmt.clean(hex"e282", 8, true), "??", "truncated sequence");
        assertEq(fmt.clean(hex"c0af", 8, true), "??", "overlong");
        assertEq(fmt.clean(hex"eda080", 8, true), "???", "surrogate");
        assertEq(fmt.clean(hex"0a09", 8, false), "??", "controls");
        assertEq(fmt.clean(bytes('"\\'), 8, true), '\\"\\\\', "json escapes");
    }

    // ────────── bug 9: sub-cent and rounding ──────────

    function test_formatUsd_subCentAndRounding() public view {
        assertEq(fmt.formatUsd(0), "0.00", "zero");
        assertEq(fmt.formatUsd(1), "&lt;0.01", "dust is not zero (XML-escaped for the card)");
        assertEq(fmt.formatUsd(4.9e15), "&lt;0.01", "below half a cent");
        assertEq(fmt.formatUsd(5e15), "0.01", "half a cent rounds up");
        assertEq(fmt.formatUsd(1.999e18), "2.00", "rounds, not truncates");
        assertEq(fmt.formatUsd(1_234_567.894e18), "1,234,567.89", "separators");
    }

    function test_tinyPosition_cardShowsLessThanCent() public {
        (PoolKey memory k, MockMetaERC20 s,, int24 tick) = _stablePair(false, 18, 18, 1);
        descriptor.setStable(address(s), true);
        _openAround(k, tick, 1e12, bytes32(uint256(0x51)));
        WalletPositionDescriptor.Row memory r = _row(bytes32(uint256(0x51)));
        assertGt(r.principalUsd, 0, "non-zero");
        assertLt(r.principalUsd, 5e15, "below half a cent");
        string memory json = _decodeJson(wallet.tokenURI(1));
        string memory svg = _decodeImage(json);
        assertTrue(_contains(svg, "&lt;$0.01"), "<$0.01 on the card");
        assertFalse(_contains(svg, "$&lt;"), "the dollar sign goes inside the bound");
    }

    // ────────── bug 10/11: decimals and symbol robustness ──────────

    function test_stableDecimals_absurdOrBroken_unpriced() public {
        uint256[3] memory bad = [uint256(78), 300, 2 ** 255];
        for (uint256 i = 0; i < bad.length; ++i) {
            MockMetaERC20 s = _tok("USDC", bad[i]);
            MockMetaERC20 v = _tok("V", 18);
            descriptor.setStable(address(s), true);
            PoolKey memory k = _pool(address(s), address(v), 500, 10, 0);
            bytes32 salt = bytes32(uint256(0x600 + i));
            _openIn(k, -100, 100, 1e15, salt);
            assertEq(_row(salt).flags & UNPRICED, UNPRICED, "absurd decimals -> unpriced");
        }
        HostileMetaERC20 h = new HostileMetaERC20(1);
        h.mint(address(wallet), 1e30);
        descriptor.setStable(address(h), true);
        MockMetaERC20 v2 = _tok("V", 18);
        _openIn(_pool(address(h), address(v2), 500, 10, 0), -100, 100, 1e15, bytes32(uint256(0x6FF)));
        assertEq(_row(bytes32(uint256(0x6FF))).flags & UNPRICED, UNPRICED, "reverting decimals -> unpriced");
        _decodeJson(wallet.tokenURI(1)); // and the whole card still renders
    }

    function test_hostileSymbols_renderWithoutRevert() public {
        MockMetaERC20 s = _tok("USDC", 6);
        descriptor.setStable(address(s), true);
        for (uint8 m = 0; m < 4; ++m) {
            HostileMetaERC20 h = new HostileMetaERC20(m);
            h.mint(address(wallet), 1e30);
            _openIn(_pool(address(h), address(s), 500, 10, 0), -100, 100, 1e12, bytes32(uint256(0x700 + m)));
        }
        uint256 g = gasleft();
        string memory uri = wallet.tokenURI(1);
        uint256 used = g - gasleft();
        assertLt(used, 5_000_000, "bounded gas despite a gas-burning symbol()");
        string memory svg = _decodeImage(_decodeJson(uri));
        assertTrue(_contains(svg, ">?</text>"), "unreadable symbol shows ?");
    }

    /// @notice A pool at an absurd price turns a position into an overflowing USD figure: that position
    /// is unpriced (the overflow is caught), never a revert of the whole card.
    function test_absurdPrice_unpricedNotReverted() public {
        MockMetaERC20 s = _tok("USDC", 0);
        MockMetaERC20 v = _tok("V", 18);
        descriptor.setStable(address(s), true);
        // A reference reading the extreme end of the price range: 1 raw V ~ 2^128 raw USDC.
        bool vIs0 = address(v) < address(s);
        MockV3Pool crazy =
            new MockV3Pool(address(v), address(s), vIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE);
        PoolKey memory none;
        descriptor.setReference(address(v), address(crazy), none);
        PoolKey memory k = _pool(address(s), address(v), 500, 10, 0);
        _openIn(k, -100, 100, 1e24, bytes32(uint256(0x91)));
        vm.expectRevert(); // the conversion overflows inside positionValue ...
        descriptor.positionValue(address(wallet), bytes32(uint256(0x91)));
        // ... and tokenURI catches it: that position is unpriced, the card still renders.
        string memory json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Pricing"), "unpriced", "absurd value is not a price");
    }

    // ────────── bug 12: native ticker from the constructor ──────────

    function test_nativeSymbol_fromConstructor() public {
        WalletPositionDescriptor d = new WalletPositionDescriptor(
            IPoolManager(address(poolManager)),
            address(this),
            address(0),
            "POL",
            new address[](0),
            new WalletPositionDescriptor.RefInit[](0)
        );
        assertEq(d.nativeSymbol(), "POL", "ticker");
    }

    // ────────── bug 7: unbounded Volatile portfolios ──────────

    function test_manyPositions_truncatedAndBoundedGas() public {
        uint256 n = 120;
        for (uint256 i = 0; i < n; ++i) {
            _open(bytes32(i + 1), -SPACING, SPACING);
        }
        uint256 g = gasleft();
        string memory uri = wallet.tokenURI(1);
        uint256 used = g - gasleft();
        emit log_named_uint("tokenURI gas, 120 positions", used);
        assertLt(used, 30_000_000, "fits an eth_call budget");

        string memory json = _decodeJson(uri);
        uint256 cap = descriptor.MAX_POSITIONS();
        assertTrue(vm.keyExistsJson(json, string.concat(".positions[", vm.toString(cap - 1), "]")), "cap listed");
        assertFalse(vm.keyExistsJson(json, string.concat(".positions[", vm.toString(cap), "]")), "no more");
        assertEq(_attr(json, "Open Positions"), "120", "true count");
        // the 1:1 test pool has no stable => unpriced dominates; with a stable it says truncated
        descriptor.setStable(Currency.unwrap(currency1), true);
        json = _decodeJson(wallet.tokenURI(1));
        assertEq(_attr(json, "Pricing"), "truncated", "truncated");
        assertFalse(_hasAttr(json, "Liquidity (USD)"), "no liquidity for a partial render");
        assertFalse(_hasAttr(json, "Unclaimed Fees (USD)"), "no fees for a partial render");
        assertTrue(_contains(_decodeImage(json), "first 40 of 120 positions"), "card says so");
    }

    // ────────── bug 13: admin ──────────

    function test_admin_onlyOwner() public {
        PoolKey memory none;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        descriptor.setStable(address(1), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        descriptor.setReference(address(1), address(0), none);
        vm.stopPrank();
    }

    function test_admin_twoStepOwnership() public {
        descriptor.transferOwnership(alice);
        assertEq(descriptor.owner(), address(this), "pending, not transferred");
        vm.prank(alice);
        descriptor.acceptOwnership();
        assertEq(descriptor.owner(), alice, "accepted");
    }

    function test_admin_setStable_emitsAndToggles() public {
        vm.expectEmit(address(descriptor));
        emit WalletPositionDescriptor.StableSet(address(7), true);
        descriptor.setStable(address(7), true);
        assertTrue(descriptor.isStable(address(7)));
        descriptor.setStable(address(7), false);
        assertFalse(descriptor.isStable(address(7)));
    }

    function test_admin_setReference_validates() public {
        MockMetaERC20 a = _tok("A", 18);
        MockMetaERC20 b = _tok("B", 18);
        MockMetaERC20 c = _tok("C", 18);
        PoolKey memory k = _pool(address(a), address(b), 500, 10, 0);
        PoolKey memory none;

        // token not in the pool
        vm.expectRevert(abi.encodeWithSelector(WalletPositionDescriptor.ReferenceMismatch.selector, address(c)));
        descriptor.setReference(address(c), address(0), k);
        MockV3Pool v3 = new MockV3Pool(address(a), address(b), 1 << 96);
        vm.expectRevert(abi.encodeWithSelector(WalletPositionDescriptor.ReferenceMismatch.selector, address(c)));
        descriptor.setReference(address(c), address(v3), none);
        // hooked v4 pool
        PoolKey memory hooked = PoolKey(k.currency0, k.currency1, k.fee, k.tickSpacing, IHooks(address(0x1234)));
        vm.expectRevert(abi.encodeWithSelector(WalletPositionDescriptor.ReferenceMismatch.selector, address(a)));
        descriptor.setReference(address(a), address(0), hooked);

        // valid both ways, then cleared
        descriptor.setReference(address(a), address(0), k);
        (address p3, bytes32 id, address q, bool is0) = descriptor.references(address(a));
        assertEq(p3, address(0));
        assertEq(id, PoolId.unwrap(k.toId()));
        assertEq(q, address(b));
        assertEq(is0, address(a) < address(b));
        descriptor.setReference(address(b), address(v3), none);
        (p3,, q,) = descriptor.references(address(b));
        assertEq(p3, address(v3));
        assertEq(q, address(a));
        descriptor.setReference(address(b), address(0), none);
        (p3, id, q,) = descriptor.references(address(b));
        assertEq(p3, address(0), "cleared");
        assertEq(id, bytes32(0), "cleared");
    }

    /// @notice A reference whose pool price reads zero (uninitialised v4 / dead v3) does not price.
    function test_reference_zeroPrice_fallsThrough() public {
        (PoolKey memory own, MockMetaERC20 s, MockMetaERC20 v, int24 tick) = _stablePair(false, 6, 8, 60_000);
        descriptor.setStable(address(s), true);
        MockV3Pool dead = new MockV3Pool(address(v), address(s), 1 << 96);
        PoolKey memory none;
        descriptor.setReference(address(v), address(dead), none);
        dead.setPrice(0);
        _openAround(own, tick, 1e12, bytes32(uint256(0x81)));
        assertEq(_row(bytes32(uint256(0x81))).flags, OWN_POOL, "falls back to the own pool, flagged");
    }

    // ────────── conversion fuzz ──────────

    function testFuzz_conversions_matchIndependentMath(uint256 amt, uint160 sp) public view {
        amt = bound(amt, 0, 2 ** 100);
        sp = uint160(bound(sp, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint256 a = fmt.q0to1(amt, sp);
        uint256 b = FullMath.mulDiv(FullMath.mulDiv(amt, sp, 1 << 96), sp, 1 << 96); // floors twice
        assertGe(a, b, "exact >= double-floored");
        assertLe(a - b, sp / (1 << 96) + 1, "differs only by the inner floor");
        uint256 c = fmt.q1to0(amt, sp);
        uint256 d = _conv(amt, sp, false);
        assertApproxEqAbs(c, d, c / 1e12 + 2, "q1to0");
        // round trip never creates value
        assertLe(fmt.q1to0(a, sp), amt, "0->1->0 <= a");
    }

    // ────────── descriptor setter / ERC-4906 (wallet side) ──────────

    function test_setPositionDescriptor_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(SingletonNFTOwned.NotOwnerNFT.selector);
        wallet.setPositionDescriptor(address(descriptor));
    }

    function test_supportsInterface_erc4906() public view {
        assertTrue(wallet.supportsInterface(0x49064906), "ERC-4906 advertised");
    }

    function test_metadataUpdate_emittedOnOpen() public {
        vm.expectEmit(address(wallet));
        emit MetadataUpdate(wallet.TOKEN_ID());
        vm.prank(owner);
        wallet.openPosition(key, -SPACING, SPACING, 1e18, bytes32(uint256(7)), 0, type(uint128).max, type(uint128).max);
    }

    function test_metadataUpdate_emittedOnClose() public {
        _open(bytes32(uint256(8)), -SPACING, SPACING);
        vm.expectEmit(address(wallet));
        emit MetadataUpdate(wallet.TOKEN_ID());
        vm.prank(owner);
        wallet.closePosition(bytes32(uint256(8)));
    }

    // ────────── helpers ──────────

    function _open(bytes32 salt, int24 tl, int24 tu) internal {
        vm.prank(owner);
        wallet.openPosition(key, tl, tu, 1e18, salt, 0, type(uint128).max, type(uint128).max);
    }

    function _swap(bool zeroForOne, int256 amt) internal {
        MockERC20(Currency.unwrap(currency0)).mint(trader, 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 1_000e18);
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        _swapIn(key, zeroForOne, amt);
    }

    /// @dev Same formatting as the descriptor's machine-readable attribute.
    function _usd2(uint256 v) internal pure returns (string memory) {
        uint256 c = (v + 5e15) / 1e16;
        return string.concat(vm.toString(c / 100), ".", c % 100 < 10 ? "0" : "", vm.toString(c % 100));
    }

    function _hasAttr(string memory json, string memory trait) internal view returns (bool) {
        for (uint256 i = 0; i < 8; ++i) {
            string memory p = string.concat(".attributes[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, p)) return false;
            if (keccak256(bytes(json.readString(string.concat(p, ".trait_type")))) == keccak256(bytes(trait))) {
                return true;
            }
        }
        return false;
    }

    function _attr(string memory json, string memory trait) internal view returns (string memory) {
        for (uint256 i = 0; i < 8; ++i) {
            string memory p = string.concat(".attributes[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, p)) break;
            if (keccak256(bytes(json.readString(string.concat(p, ".trait_type")))) == keccak256(bytes(trait))) {
                return json.readString(string.concat(p, ".value"));
            }
        }
        revert(string.concat("attribute missing: ", trait));
    }

    /// @dev Strip the `data:application/json;base64,` prefix and base64-decode via ffi -> raw JSON.
    function _decodeJson(string memory dataUri) internal returns (string memory) {
        return _b64(_afterPrefix(dataUri, JSON_PREFIX));
    }

    /// @dev Decode the base64 SVG out of the `image` field of an already-decoded JSON string.
    function _decodeImage(string memory json) internal returns (string memory) {
        return _b64(_afterPrefix(json.readString(".image"), "data:image/svg+xml;base64,"));
    }

    function _b64(string memory b64) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat("printf '%s' '", b64, "' | base64 -d");
        return string(vm.ffi(cmd));
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
}
