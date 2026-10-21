// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {PositionState} from "./lib/PositionState.sol";
import {DescriptorLib, DescriptorArt} from "./lib/DescriptorLib.sol";

/// @title WalletPositionDescriptor
/// @notice On-chain `tokenURI` renderer for the NFT-owned LP managers: a base64 `data:` JSON with a
/// per-position breakdown plus an SVG card. Deployed once per chain and shared; managers delegate
/// `tokenURI` here so the rendering bytecode stays out of the (EIP-170-bound) clones.
///
/// **Valuation (task_055) — prices always come from Uniswap pools, never a $1-per-token guess.**
/// Each leg of a position is valued, in this order:
///   1. a stablecoin on the allowlist is $1;
///   2. a token with a protocol-curated **reference pool** (v4 key or v3 pool, token/stable or
///      token/X with X itself referenced to a stable — at most two hops) is priced through it;
///   3. otherwise, when the other leg of the manager's **own** pool is a stablecoin, through that pool's
///      price — flagged "own pool" on the card, since a thin pool picked by the creator sets it;
///   4. otherwise the leg is **unpriced** and the card says so instead of printing a number.
/// The card shows two sums (task_059): **Liquidity** — the open positions' principal at the live price,
/// idle balances excluded — and **Unclaimed fees**, net of the 10 % protocol cut. No APR: fees reset on
/// every realization, so an on-chain renderer has no honest denominator for one.
contract WalletPositionDescriptor is IWalletDescriptor, Ownable2Step {
    using Strings for uint256;
    using StateLibrary for IPoolManager;

    uint256 private constant USD = 1e18;
    /// @dev Mirrors `BaseLPManager.PROTOCOL_FEE_BPS` (constant there, rounded up in the protocol's favour).
    uint256 private constant PROTOCOL_FEE_BPS = 1000;
    /// @notice Positions valued and listed per render; a larger portfolio renders the first `MAX_POSITIONS`
    /// and says so (bounds `tokenURI` gas for Volatile managers, whose position count is unbounded).
    uint256 public constant MAX_POSITIONS = 40;
    /// @dev Gas handed to each untrusted metadata call (`symbol`, `decimals`, `name`).
    uint256 private constant META_GAS = 40_000;

    // Pricing flags per position / portfolio.
    uint8 private constant OWN_POOL = 1;
    uint8 private constant UNPRICED = 2;

    /// @notice A token's reference price source. Exactly one of `v3Pool` / `v4Id` is set.
    /// @param v3Pool    Uniswap v3 pool address (read via `slot0()`), or zero.
    /// @param v4Id      Uniswap v4 pool id (read via the PoolManager), or zero.
    /// @param quote     The pool's other currency (WETH canonicalised to native `address(0)`).
    /// @param tokenIs0  Whether the priced token is the pool's token0.
    struct Ref {
        address v3Pool;
        bytes32 v4Id;
        address quote;
        bool tokenIs0;
    }

    /// @notice Constructor seed for one reference entry (see {setReference}).
    struct RefInit {
        address token;
        address v3Pool;
        PoolKey v4Key;
    }

    /// @notice One position, valued once (principal at the live price, fees net of the protocol cut).
    struct Row {
        bytes32 salt;
        V4PositionManager.Position p;
        uint256 a0;
        uint256 a1;
        uint256 f0;
        uint256 f1;
        uint256 principalUsd;
        uint256 feeUsd;
        uint8 flags;
    }

    /// @notice The chain's v4 PoolManager (reference v4 pools are read through it).
    IPoolManager public immutable POOL_MANAGER;
    /// @notice Static artwork (the watermark), deployed by the constructor to keep this runtime small.
    DescriptorArt public immutable ART;
    /// @notice The chain's wrapped native token; treated as the same asset as native `address(0)`.
    address public immutable WETH;

    /// @notice Stablecoins valued at $1.
    mapping(address => bool) public isStable;
    /// @notice Ticker shown for the native currency (`ETH`, `POL`, …).
    string public nativeSymbol;
    /// @notice Reference price source per token (native and WETH share the `address(0)` entry).
    mapping(address => Ref) public references;

    event StableSet(address indexed token, bool stable);
    event ReferenceSet(address indexed token, address v3Pool, bytes32 v4Id, address quote);

    error ReferenceMismatch(address token);

    string private constant DESCRIPTION =
        "NFT-owned Uniswap V4 liquidity wallet. Holding this token controls the wallet and all of its positions.";

    /// @param poolManager   The chain's v4 PoolManager.
    /// @param initialOwner  Admin of the stable allowlist and the reference registry (Ownable2Step).
    /// @param weth          The chain's wrapped native token (aliased to native for pricing).
    /// @param nativeSymbol_ Ticker shown for the native currency.
    /// @param stablecoins   Initial $1 allowlist.
    /// @param refs          Initial reference pools.
    constructor(
        IPoolManager poolManager,
        address initialOwner,
        address weth,
        string memory nativeSymbol_,
        address[] memory stablecoins,
        RefInit[] memory refs
    ) Ownable(initialOwner) {
        POOL_MANAGER = poolManager;
        ART = new DescriptorArt();
        WETH = weth;
        nativeSymbol = nativeSymbol_;
        for (uint256 i = 0; i < stablecoins.length; ++i) {
            _setStable(stablecoins[i], true);
        }
        for (uint256 i = 0; i < refs.length; ++i) {
            _setReference(refs[i].token, refs[i].v3Pool, refs[i].v4Key);
        }
    }

    // ────────── admin ──────────

    /// @notice Add or remove a $1 stablecoin. Owner-only.
    function setStable(address token, bool stable) external onlyOwner {
        _setStable(token, stable);
    }

    /// @notice Set `token`'s reference pool: a v3 pool (`v3Pool != 0`) or a hookless v4 pool (`v4Key`);
    /// both empty (`v3Pool == 0`, `v4Key.tickSpacing == 0`) clears the entry. The pool must contain
    /// `token` (WETH and native count as one asset). Owner-only.
    function setReference(address token, address v3Pool, PoolKey calldata v4Key) external onlyOwner {
        _setReference(token, v3Pool, v4Key);
    }

    function _setStable(address token, bool stable) private {
        isStable[token] = stable;
        emit StableSet(token, stable);
    }

    function _setReference(address token, address v3Pool, PoolKey memory k) private {
        address t = _canon(token);
        Ref memory r;
        address c0;
        address c1;
        if (v3Pool != address(0)) {
            r.v3Pool = v3Pool;
            c0 = IUniswapV3PoolTokens(v3Pool).token0();
            c1 = IUniswapV3PoolTokens(v3Pool).token1();
        } else if (k.tickSpacing != 0) {
            if (address(k.hooks) != address(0)) revert ReferenceMismatch(token);
            r.v4Id = PoolId.unwrap(k.toId());
            c0 = Currency.unwrap(k.currency0);
            c1 = Currency.unwrap(k.currency1);
        }
        if (r.v3Pool != address(0) || r.v4Id != 0) {
            r.tokenIs0 = _canon(c0) == t;
            r.quote = _canon(r.tokenIs0 ? c1 : c0);
            if (!r.tokenIs0 && _canon(c1) != t) revert ReferenceMismatch(token);
        }
        references[t] = r;
        emit ReferenceSet(t, r.v3Pool, r.v4Id, r.quote);
    }

    // ────────── tokenURI ──────────

    /// @inheritdoc IWalletDescriptor
    function tokenURI(address wallet, uint256 tokenId) external view returns (string memory) {
        V4PositionManager w = V4PositionManager(wallet);
        uint256 n = w.openPositionCount();
        uint256 m = n > MAX_POSITIONS ? MAX_POSITIONS : n;
        Row[] memory rows = new Row[](m);
        for (uint256 i = 0; i < m; ++i) {
            bytes32 salt = w.openSalts(i);
            try this.positionValue(wallet, salt) returns (Row memory r) {
                rows[i] = r;
            } catch {
                rows[i].flags = UNPRICED; // a position that cannot be read is never valued at anything
            }
            rows[i].salt = salt;
        }
        return string.concat("data:application/json;base64,", Base64.encode(bytes(_json(wallet, tokenId, n, rows))));
    }

    /// @notice Value one position of `wallet`: amounts at the live price, fees net of the protocol cut,
    /// and both in 1e18 USD with pricing flags (bit 0 = a leg priced by its own pool, bit 1 = unpriced).
    /// External so {tokenURI} can isolate a misbehaving position with try/catch; usable off-chain too.
    function positionValue(address wallet, bytes32 salt) external view returns (Row memory r) {
        V4PositionManager w = V4PositionManager(wallet);
        r.p = w.positionOf(salt);
        IPoolManager pm = w.POOL_MANAGER();
        (r.a0, r.a1, r.f0, r.f1) = PositionState.value(pm, wallet, salt, r.p);
        r.f0 -= (r.f0 * PROTOCOL_FEE_BPS + 9_999) / 10_000;
        r.f1 -= (r.f1 * PROTOCOL_FEE_BPS + 9_999) / 10_000;
        (uint160 own,,,) = pm.getSlot0(r.p.key.toId());

        (uint256 p0, uint8 g0) = _legUsd(r.p.key, own, true, r.a0);
        (uint256 p1, uint8 g1) = _legUsd(r.p.key, own, false, r.a1);
        (uint256 e0, uint8 h0) = _legUsd(r.p.key, own, true, r.f0);
        (uint256 e1, uint8 h1) = _legUsd(r.p.key, own, false, r.f1);
        r.flags = g0 | g1 | h0 | h1;
        // An absurd figure (a broken pool or token) is not a price; the cap also keeps the portfolio sums
        // in {_totals} far from overflow. (An overflow here reverts → caught → unpriced.)
        if (p0 + p1 + e0 + e1 > 2 ** 200) r.flags |= UNPRICED;
        if (r.flags & UNPRICED == 0) (r.principalUsd, r.feeUsd) = (p0 + p1, e0 + e1);
    }

    // ────────── pricing ──────────

    /// @notice USD (1e18) of `amount` raw units of `token` through the allowlist and the reference
    /// registry only (no own-pool fallback); `ok == false` when the token has no price source. Lets a
    /// frontend value idle balances on exactly the card's terms.
    function priceUsd(address token, uint256 amount) external view returns (uint256 usd, bool ok) {
        return _usd(token, amount, 0);
    }

    /// @dev USD (1e18) of `amt` of one leg of `key` (`zero` ⇒ currency0) and its pricing flag.
    function _legUsd(PoolKey memory key, uint160 ownSp, bool zero, uint256 amt)
        private
        view
        returns (uint256 usd, uint8 flag)
    {
        if (amt == 0) return (0, 0);
        address t = Currency.unwrap(zero ? key.currency0 : key.currency1);
        bool ok;
        (usd, ok) = _usd(t, amt, 0);
        if (ok) return (usd, 0);
        // Fallback: the manager's own pool, only against a stable leg.
        address other = Currency.unwrap(zero ? key.currency1 : key.currency0);
        if (ownSp != 0 && isStable[other]) {
            (usd, ok) = _stableUsd(other, zero ? DescriptorLib.q0to1(amt, ownSp) : DescriptorLib.q1to0(amt, ownSp));
            if (ok) return (usd, OWN_POOL);
        }
        return (0, UNPRICED);
    }

    /// @dev USD (1e18) of `amt` raw units of `t` via the allowlist and the reference registry (≤ 2 hops).
    function _usd(address t, uint256 amt, uint256 hop) private view returns (uint256, bool) {
        if (isStable[t]) return _stableUsd(t, amt);
        if (hop == 2) return (0, false);
        Ref memory r = references[_canon(t)];
        uint160 sp;
        if (r.v3Pool != address(0)) {
            (bool ok, bytes memory d) = r.v3Pool.staticcall(abi.encodeWithSelector(0x3850c7bd)); // slot0()
            if (ok && d.length >= 32) sp = uint160(uint256(bytes32(d)));
        } else if (r.v4Id != 0) {
            (sp,,,) = POOL_MANAGER.getSlot0(PoolId.wrap(r.v4Id));
        }
        if (sp == 0) return (0, false);
        return _usd(r.quote, r.tokenIs0 ? DescriptorLib.q0to1(amt, sp) : DescriptorLib.q1to0(amt, sp), hop + 1);
    }

    /// @dev USD (1e18) of `amt` raw units of the stablecoin `s`; fails on unreadable / absurd decimals.
    function _stableUsd(address s, uint256 amt) private view returns (uint256, bool) {
        (bool ok, uint256 dec) = s == address(0) ? (true, 18) : _word(s, 0x313ce567); // decimals()
        if (!ok || dec > 77) return (0, false);
        return (FullMath.mulDiv(amt, USD, 10 ** dec), true);
    }

    /// @dev WETH and native are one asset for pricing.
    function _canon(address t) private view returns (address) {
        return t == WETH ? address(0) : t;
    }

    // ────────── bounded external reads ──────────

    /// @dev `staticcall` with a gas cap that copies at most 128 bytes of return data (a hostile token
    /// can neither burn the caller's gas nor blow up memory with a huge return).
    function _boundedCall(address t, bytes memory data) private view returns (bool ok, bytes memory out) {
        out = new bytes(128);
        assembly ("memory-safe") {
            ok := staticcall(META_GAS, t, add(data, 32), mload(data), 0, 0)
            let len := returndatasize()
            if gt(len, 128) { len := 128 }
            returndatacopy(add(out, 32), 0, len)
            mstore(out, len)
        }
    }

    /// @dev A single return word from a zero-argument view selector.
    function _word(address t, bytes4 sel) private view returns (bool, uint256) {
        if (t.code.length == 0) return (false, 0);
        (bool ok, bytes memory d) = _boundedCall(t, abi.encodeWithSelector(sel));
        if (!ok || d.length < 32) return (false, 0);
        return (true, uint256(bytes32(d)));
    }

    /// @dev A string (or bytes32) returned by a zero-argument selector, at most 64 raw bytes; "" on failure.
    function _text(address t, bytes4 sel) private view returns (bytes memory s) {
        (bool ok, bytes memory d) = _boundedCall(t, abi.encodeWithSelector(sel));
        if (!ok) return "";
        uint256 start = 64;
        uint256 len;
        if (d.length == 32) {
            // bytes32-style metadata (e.g. MKR): strip the zero padding.
            start = 0;
            while (len < 32 && d[len] != 0) ++len;
        } else {
            if (d.length < 64 || uint256(bytes32(d)) != 32) return "";
            assembly ("memory-safe") {
                len := mload(add(d, 64))
            }
            if (len > d.length - 64) len = d.length - 64;
        }
        s = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(s, 32), add(add(d, 32), start), len)
        }
    }

    /// @dev Display ticker of a currency, XML-safe; native ⇒ the constructor's native symbol.
    function _symbol(Currency c) private view returns (string memory) {
        address t = Currency.unwrap(c);
        bytes memory s;
        if (t == address(0)) {
            s = bytes(nativeSymbol);
        } else {
            s = _text(t, 0x95d89b41); // symbol()
        }
        if (s.length == 0) return "?";
        // 8 bytes: a chip's label has 68 px before the next chip (92 px pitch, 12 px monospace ≈ 7.2 px a
        // glyph), and the third chip must stay clear of the `+k` counter at x = 296 (task_063).
        return DescriptorLib.clean(s, 8, false);
    }

    // ────────── JSON ──────────

    function _json(address wallet, uint256 tokenId, uint256 n, Row[] memory rows) private view returns (string memory) {
        bytes memory rawName = _text(wallet, 0x06fdde03); // name()
        (uint256 liq, uint256 fees, uint8 flags) = _totals(rows);
        if (n > rows.length) flags |= 4; // truncated

        string memory head = string.concat(
            '{"name":"',
            DescriptorLib.clean(rawName, 48, true),
            " #",
            tokenId.toString(),
            '","description":"',
            DESCRIPTION,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(
                bytes(_svg(DescriptorLib.clean(rawName, 48, false), rawName.length > 28, n, rows, liq, fees, flags))
            )
        );
        return string.concat(
            head, '","attributes":[', _attributes(n, liq, fees, flags), '],"positions":[', _positionsJson(rows), "]}"
        );
    }

    /// @dev Portfolio sums over the rendered rows: principal ("Liquidity") and net unclaimed fees.
    function _totals(Row[] memory rows) private pure returns (uint256 liq, uint256 fees, uint8 flags) {
        for (uint256 i = 0; i < rows.length; ++i) {
            flags |= rows[i].flags;
            liq += rows[i].principalUsd;
            fees += rows[i].feeUsd;
        }
    }

    function _pricing(uint8 flags) private pure returns (string memory) {
        if (flags & UNPRICED != 0) return "unpriced";
        if (flags & 4 != 0) return "truncated";
        if (flags & OWN_POOL != 0) return "own pool";
        return "reference pools";
    }

    function _attributes(uint256 n, uint256 liq, uint256 fees, uint8 flags) private pure returns (string memory out) {
        out = string.concat(
            '{"trait_type":"Open Positions","value":"',
            n.toString(),
            '"},{"trait_type":"Pricing","value":"',
            _pricing(flags),
            '"}'
        );
        if (flags & (UNPRICED | 4) == 0) {
            out = string.concat(
                out,
                ',{"trait_type":"Liquidity (USD)","value":"',
                _usdAttr(liq),
                '"},{"trait_type":"Unclaimed Fees (USD)","value":"',
                _usdAttr(fees),
                '"}'
            );
        }
    }

    /// @dev Machine-readable USD: rounded to the cent, no separators.
    function _usdAttr(uint256 v) private pure returns (string memory) {
        uint256 c = (v + 5e15) / 1e16;
        return string.concat((c / 100).toString(), ".", c % 100 < 10 ? "0" : "", (c % 100).toString());
    }

    /// @dev Join the per-position objects in one pass (no quadratic re-concatenation).
    function _positionsJson(Row[] memory rows) private pure returns (string memory) {
        bytes[] memory parts = new bytes[](rows.length);
        uint256 len;
        for (uint256 i = 0; i < rows.length; ++i) {
            parts[i] = bytes(_positionJson(rows[i]));
            len += parts[i].length + 1;
        }
        bytes memory out = new bytes(len == 0 ? 0 : len - 1);
        uint256 o;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (i != 0) out[o++] = ",";
            bytes memory pt = parts[i];
            assembly ("memory-safe") {
                mcopy(add(add(out, 32), o), add(pt, 32), mload(pt))
            }
            o += pt.length;
        }
        return string(out);
    }

    function _positionJson(Row memory r) private pure returns (string memory) {
        string memory a = string.concat(
            '{"salt":"',
            Strings.toHexString(uint256(r.salt), 32),
            '","currency0":"',
            Strings.toHexString(Currency.unwrap(r.p.key.currency0)),
            '","currency1":"',
            Strings.toHexString(Currency.unwrap(r.p.key.currency1)),
            '","fee":',
            uint256(r.p.key.fee).toString(),
            ',"tickLower":',
            Strings.toStringSigned(int256(r.p.tickLower)),
            ',"tickUpper":',
            Strings.toStringSigned(int256(r.p.tickUpper)),
            ',"liquidity":"',
            uint256(r.p.liquidity).toString()
        );
        string memory b = string.concat(
            '","amount0":"',
            r.a0.toString(),
            '","amount1":"',
            r.a1.toString(),
            '","fees0":"',
            r.f0.toString(),
            '","fees1":"',
            r.f1.toString(),
            '","pricing":"',
            _pricing(r.flags)
        );
        return string.concat(
            a,
            b,
            r.flags & UNPRICED == 0
                ? string.concat('","liquidityUsd":"', _usdAttr(r.principalUsd), '","feesUsd":"', _usdAttr(r.feeUsd))
                : "",
            '"}'
        );
    }

    // ────────── image ──────────

    /// @param longName More than 28 raw bytes: the title drops to 13 px so 32 monospace glyphs still fit
    /// the 280 px line (task_063; multi-byte names are narrower per byte, so this is conservative).
    function _svg(string memory nm, bool longName, uint256 n, Row[] memory rows, uint256 liq, uint256 fees, uint8 flags)
        private
        view
        returns (string memory)
    {
        string memory top = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320">',
            '<rect width="320" height="320" fill="#0b1021"/>',
            ART.logo(),
            '<text x="20" y="40" fill="#4AFEBF" font-family="monospace" font-size="',
            longName ? "13" : "16",
            '">',
            nm,
            '</text><text x="20" y="92" fill="#9aa7bd" font-family="monospace" font-size="13">Open positions: ',
            n.toString(),
            '</text><text x="20" y="128" fill="#9aa7bd" font-family="monospace" font-size="13">Liquidity</text>'
        );
        bool priced = flags & UNPRICED == 0;
        bool atLeast = flags & 4 != 0;
        string memory value = priced ? _money(atLeast, liq) : "unpriced";
        string memory note = !priced
            ? "no pool price for some tokens"
            : flags & 4 != 0
                ? string.concat("first ", rows.length.toString(), " of ", n.toString(), " positions")
                : flags & OWN_POOL != 0 ? "priced by own pool" : "";
        string memory mid = string.concat(
            '<text x="20" y="160" fill="#ffffff" font-family="monospace" font-size="26">',
            value,
            '</text><text x="20" y="182" fill="#5b6b86" font-family="monospace" font-size="11">',
            note,
            '</text><text x="20" y="206" fill="#9aa7bd" font-family="monospace" font-size="13">',
            priced ? string.concat("Unclaimed fees: ", _money(atLeast, fees)) : "",
            "</text>"
        );
        return string.concat(
            top,
            mid,
            _icons(rows),
            '<text x="20" y="306" fill="#5b6b86" font-family="monospace" font-size="11">Uniswap V4 &#183; NFT owned</text>',
            "</svg>"
        );
    }

    /// @dev `$1,234.56`, `<$0.01` for dust (the `$` goes inside the bound, task_063), `≥ ` before either
    /// when the render is truncated.
    function _money(bool atLeast, uint256 v) private pure returns (string memory) {
        string memory f = DescriptorLib.formatUsd(v);
        f = bytes(f)[0] == "&" ? "&lt;$0.01" : string.concat("$", f);
        return atLeast ? string.concat("&#8805; ", f) : f;
    }

    /// @dev Up to three distinct currency chips; `+k` if more exist among the rendered positions.
    function _icons(Row[] memory rows) private view returns (string memory out) {
        Currency[] memory curs = new Currency[](2 * rows.length);
        uint256 cn;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (rows[i].p.liquidity == 0) continue;
            cn = _pushDistinct(curs, cn, rows[i].p.key.currency0);
            cn = _pushDistinct(curs, cn, rows[i].p.key.currency1);
        }
        uint256 show = cn > 3 ? 3 : cn;
        for (uint256 i = 0; i < show; ++i) {
            out = string.concat(out, DescriptorLib.tokenIcon(_symbol(curs[i]), 20 + i * 92, 236));
        }
        if (cn > 3) {
            out = string.concat(
                out,
                '<text x="296" y="249" fill="#9aa7bd" font-family="monospace" font-size="12">+',
                (cn - 3).toString(),
                "</text>"
            );
        }
    }

    function _pushDistinct(Currency[] memory arr, uint256 count, Currency c) private pure returns (uint256) {
        for (uint256 i = 0; i < count; ++i) {
            if (Currency.unwrap(arr[i]) == Currency.unwrap(c)) return count;
        }
        arr[count] = c;
        return count + 1;
    }
}

/// @dev The two v3 pool getters the reference setter needs.
interface IUniswapV3PoolTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}
