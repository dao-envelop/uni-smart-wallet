// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title DescriptorLib
/// @notice Pure SVG/markup + number-formatting helpers for {WalletPositionDescriptor}. Kept in a
/// library so the bulky logo markup and string math stay readable and out of the renderer. All
/// `internal` (inlined into the descriptor — no separate deployment).
library DescriptorLib {
    using Strings for uint256;

    /// @dev Envelop wordmark (vectors from `stablelp-ui/public/envelop.svg`), wrapped as a faint
    /// centered watermark for a 320×320 card. Inlined as a single-quoted literal so the inner
    /// double-quoted SVG attributes need no escaping.
    function logo() internal pure returns (string memory) {
        return '<g opacity="0.13" transform="translate(38,44) scale(2.03)">'
            '<path d="M36.2804 47.4928C35.6654 47.0073 35.2684 46.2976 35.1766 45.5195C35.0848 44.7414 35.3057 43.9588 35.7908 43.3435L40.8057 37.0032C41.2918 36.3881 42.0024 35.9912 42.7811 35.9C43.5598 35.8087 44.3428 36.0306 44.958 36.5167C45.5731 37.0028 45.97 37.7133 46.0612 38.492C46.1525 39.2707 45.9306 40.0538 45.4445 40.6689L40.4296 47.0032C39.9442 47.6182 39.2344 48.0152 38.4563 48.107C37.6783 48.1988 36.8956 47.9778 36.2804 47.4928Z" fill="#4AFEBF"/>'
            '<path d="M69.8982 58.5551C69.8982 61.136 68.873 63.6112 67.048 65.4362C65.223 67.2612 62.7478 68.2864 60.1669 68.2864C57.586 68.2864 55.1108 67.2612 53.2858 65.4362C51.4608 63.6112 50.4355 61.136 50.4355 58.5551C50.4355 55.9742 51.4608 53.499 53.2858 51.674C55.1108 49.849 57.586 48.8237 60.1669 48.8237C62.7478 48.8237 65.223 49.849 67.048 51.674C68.873 53.499 69.8982 55.9742 69.8982 58.5551Z" fill="#51EEDA"/>'
            '<path fill-rule="evenodd" clip-rule="evenodd" d="M66.6218 98.3522C65.8271 99.2873 64.8385 100.038 63.7247 100.554C62.6108 101.069 61.3983 101.336 60.171 101.336C58.9438 101.336 57.7313 101.069 56.6174 100.554C55.5036 100.038 54.515 99.2873 53.7203 98.3522L25.7322 65.4149C24.4324 63.8846 23.7188 61.9421 23.7188 59.9343C23.7188 57.9265 24.4324 55.984 25.7322 54.4537L28.5382 51.1582C28.8924 50.7168 29.3315 50.351 29.8296 50.0823C30.3276 49.8135 30.8745 49.6474 31.4379 49.5938C32.0012 49.5401 32.5696 49.5999 33.1095 49.7697C33.6493 49.9395 34.1496 50.2158 34.5808 50.5823C35.012 50.9488 35.3653 51.3981 35.6199 51.9035C35.8744 52.409 36.025 52.9603 36.0628 53.525C36.1006 54.0896 36.0248 54.6561 35.8398 55.1909C35.6548 55.7258 35.3645 56.2181 34.986 56.6388L32.18 59.9343L60.1681 92.8716L68.2815 83.3194C69.0091 82.4643 70.0465 81.9334 71.1655 81.8432C72.2846 81.7531 73.3936 82.1112 74.2487 82.8388C75.1037 83.5663 75.6347 84.6038 75.7248 85.7228C75.8149 86.8419 75.4568 87.9509 74.7293 88.8059L66.6218 98.3522ZM84.1143 71.2238C83.6903 70.8638 83.3414 70.4237 83.0875 69.9287C82.8337 69.4337 82.6799 68.8935 82.635 68.339C82.5901 67.7845 82.655 67.2267 82.8258 66.6972C82.9967 66.1678 83.2702 65.6773 83.6307 65.2537L88.1561 59.9403L60.1681 27.003L54.2755 33.9343C53.5385 34.7534 52.511 35.2529 51.4115 35.3264C50.312 35.4 49.2272 35.0419 48.3876 34.3282C47.548 33.6145 47.0198 32.6015 46.9152 31.5046C46.8107 30.4076 47.1381 29.3131 47.8278 28.4537L53.7203 21.5224C54.515 20.5883 55.5032 19.838 56.6165 19.3235C57.7298 18.809 58.9416 18.5425 60.1681 18.5425C61.3945 18.5425 62.6063 18.809 63.7196 19.3235C64.8329 19.838 65.8211 20.5883 66.6158 21.5224L94.6039 54.4537C97.2905 57.6179 97.2905 62.2567 94.6039 65.4149L90.0785 70.7403C89.3515 71.5949 88.3149 72.1259 87.1965 72.2166C86.0781 72.3073 84.9695 71.9502 84.1143 71.2238Z" fill="url(#elg0)"/>'
            '<path fill-rule="evenodd" clip-rule="evenodd" d="M60.1663 8.69847C46.5777 8.69847 33.5457 14.0965 23.9371 23.7051C14.3286 33.3137 8.93052 46.3457 8.93052 59.9343C8.93052 73.5229 14.3286 86.5549 23.9371 96.1635C33.5457 105.772 46.5777 111.17 60.1663 111.17C60.7222 111.17 61.2726 111.28 61.7862 111.492C62.2997 111.705 62.7663 112.017 63.1594 112.41C63.5525 112.803 63.8642 113.27 64.077 113.783C64.2897 114.297 64.3992 114.847 64.3992 115.403C64.3992 115.959 64.2897 116.509 64.077 117.023C63.8642 117.536 63.5525 118.003 63.1594 118.396C62.7663 118.789 62.2997 119.101 61.7862 119.314C61.2726 119.526 60.7222 119.636 60.1663 119.636C27.1932 119.636 0.464844 92.9074 0.464844 59.9343C0.464844 26.9612 27.1932 0.23877 60.1663 0.23877C61.289 0.23877 62.3656 0.684728 63.1594 1.47854C63.9532 2.27235 64.3992 3.34899 64.3992 4.47161C64.3992 5.59422 63.9532 6.67086 63.1594 7.46467C62.3656 8.25848 61.289 8.70444 60.1663 8.70444V8.69847Z" fill="url(#elg1)"/>'
            '<path fill-rule="evenodd" clip-rule="evenodd" d="M96.2026 102.316C95.414 101.519 94.9742 100.441 94.9798 99.3192C94.9854 98.1976 95.4359 97.124 96.2325 96.3343C101.048 91.5754 104.868 85.9066 107.473 79.6577C110.077 73.4087 111.413 66.7043 111.403 59.9343C111.403 45.7015 105.612 32.8299 96.2325 23.5403C95.8259 23.1518 95.5008 22.6862 95.2761 22.1706C95.0515 21.655 94.9319 21.0999 94.9242 20.5376C94.9166 19.9752 95.021 19.417 95.2315 18.8955C95.442 18.3741 95.7543 17.8997 96.1502 17.5003C96.5461 17.1009 97.0176 16.7843 97.5371 16.5691C98.0567 16.354 98.614 16.2445 99.1763 16.2471C99.7387 16.2497 100.295 16.3644 100.812 16.5844C101.33 16.8044 101.799 17.1253 102.191 17.5284C107.8 23.0732 112.251 29.6774 115.285 36.9572C118.32 44.237 119.878 52.0473 119.868 59.9343C119.879 67.8223 118.321 75.6338 115.287 82.9147C112.252 90.1955 107.8 96.8007 102.191 102.346C101.796 102.738 101.327 103.047 100.813 103.258C100.298 103.468 99.7466 103.575 99.1905 103.572C98.6344 103.569 98.0843 103.457 97.5716 103.242C97.0589 103.026 96.5938 102.712 96.2026 102.316Z" fill="url(#elg2)"/>'
            '<path d="M85.3485 111.188C85.3485 112.394 84.8692 113.552 84.0161 114.405C83.1629 115.258 82.0058 115.737 80.7993 115.737C79.5927 115.737 78.4356 115.258 77.5824 114.405C76.7293 113.552 76.25 112.394 76.25 111.188C76.25 109.981 76.7293 108.824 77.5824 107.971C78.4356 107.118 79.5927 106.639 80.7993 106.639C82.0058 106.639 83.1629 107.118 84.0161 107.971C84.8692 108.824 85.3485 109.981 85.3485 111.188Z" fill="#4AFEBF"/>'
            "<defs>"
            '<linearGradient id="elg0" x1="60" y1="101" x2="60" y2="18" gradientUnits="userSpaceOnUse"><stop stop-color="#4AFEBF"/><stop offset="1" stop-color="#51EEDA"/></linearGradient>'
            '<linearGradient id="elg1" x1="32" y1="0" x2="32" y2="120" gradientUnits="userSpaceOnUse"><stop stop-color="#4AFEBF"/><stop offset="1" stop-color="#51EEDA"/></linearGradient>'
            '<linearGradient id="elg2" x1="107" y1="104" x2="107" y2="16" gradientUnits="userSpaceOnUse"><stop stop-color="#4AFEBF"/><stop offset="1" stop-color="#51EEDA"/></linearGradient>'
            "</defs>" "</g>";
    }

    /// @dev A small coin glyph + ticker for one stable, anchored at top-left (`x`,`y`). Known
    /// stables get their brand color; everything else a neutral coin.
    function tokenIcon(string memory sym, uint256 x, uint256 y) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(sym));
        string memory color = "#6b7280";
        if (h == keccak256("USDC")) color = "#2775CA";
        else if (h == keccak256("USDT")) color = "#26A17B";
        else if (h == keccak256("DAI")) color = "#F5AC37";
        return string.concat(
            '<circle cx="',
            (x + 9).toString(),
            '" cy="',
            (y + 9).toString(),
            '" r="9" fill="',
            color,
            '"/><text x="',
            (x + 24).toString(),
            '" y="',
            (y + 13).toString(),
            '" fill="#cdd6e3" font-family="monospace" font-size="12">',
            sym,
            "</text>"
        );
    }

    /// @dev Format a 1e18-scaled value as `1,234.56`, rounded half-up to the cent. A non-zero value that
    /// rounds to nothing renders `<0.01` (XML-escaped: this goes into the SVG) rather than a misleading
    /// `0.00` (task_055).
    function formatUsd(uint256 scaled1e18) internal pure returns (string memory) {
        if (scaled1e18 != 0 && scaled1e18 < 5e15) return "&lt;0.01";
        uint256 c = scaled1e18 / 1e16 + ((scaled1e18 % 1e16) >= 5e15 ? 1 : 0); // whole cents, rounded
        return string.concat(_commas(c / 100), ".", _two(c % 100));
    }

    /// @dev token0 raw → token1 raw at `sp`: a0 · sqrtP² / 2^192. Exact single mulDiv while sqrtP² fits
    /// 256 bits, else pre-scaled by 2^64 (the split `OracleLibrary.getQuoteAtTick` uses).
    function q0to1(uint256 a0, uint160 sp) internal pure returns (uint256) {
        if (sp <= type(uint128).max) return FullMath.mulDiv(a0, uint256(sp) * sp, 1 << 192);
        return FullMath.mulDiv(a0, FullMath.mulDiv(sp, sp, 1 << 64), 1 << 128);
    }

    /// @dev token1 raw → token0 raw at `sp`: a1 · 2^192 / sqrtP².
    function q1to0(uint256 a1, uint160 sp) internal pure returns (uint256) {
        if (sp <= type(uint128).max) return FullMath.mulDiv(a1, 1 << 192, uint256(sp) * sp);
        return FullMath.mulDiv(a1, 1 << 128, FullMath.mulDiv(sp, sp, 1 << 64));
    }

    /// @dev Format basis points as a percentage: `1234` ⇒ `12.34%`.
    function formatPercentBps(uint256 bps) internal pure returns (string memory) {
        return string.concat((bps / 100).toString(), ".", _two(bps % 100), "%");
    }

    /// @dev Make untrusted text (a token `symbol()`, a manager `name()`) safe to embed: keep at most
    /// `maxLen` bytes without splitting a UTF-8 sequence, replace every byte that is not part of a
    /// well-formed sequence — and every control character — with `?`, then escape for the target:
    /// JSON string (`"` and `\`) or XML text (`&`, `<`, `>`, `"`, `'`). One pass, linear.
    function clean(bytes memory s, uint256 maxLen, bool json) internal pure returns (string memory) {
        bytes memory out = new bytes(s.length * 6 + 6); // worst case: every byte → `&apos;`
        uint256 o;
        uint256 i;
        while (i < s.length) {
            uint8 b = uint8(s[i]);
            uint256 n = _seqLen(s, i);
            if (i + (n == 0 ? 1 : n) > maxLen) break; // never cut a code point; stop at the cap
            if (n > 1) {
                for (uint256 k; k < n; ++k) {
                    out[o++] = s[i + k];
                }
                i += n;
                continue;
            }
            ++i;
            bytes memory e;
            if (n == 0 || b < 0x20 || b == 0x7f) e = "?";
            else if (json && b == 0x22) e = '\\"';
            else if (json && b == 0x5c) e = "\\\\";
            else if (!json && b == 0x26) e = "&amp;";
            else if (!json && b == 0x3c) e = "&lt;";
            else if (!json && b == 0x3e) e = "&gt;";
            else if (!json && b == 0x22) e = "&quot;";
            else if (!json && b == 0x27) e = "&apos;";
            else e = abi.encodePacked(b);
            for (uint256 k; k < e.length; ++k) {
                out[o++] = e[k];
            }
        }
        assembly ("memory-safe") {
            mstore(out, o)
        }
        return string(out);
    }

    /// @dev Length of the well-formed UTF-8 sequence starting at `s[i]` (1 for ASCII), or 0 when the
    /// bytes there are not one (stray continuation, overlong form, surrogate, > U+10FFFF, truncated).
    function _seqLen(bytes memory s, uint256 i) private pure returns (uint256) {
        uint8 b = uint8(s[i]);
        if (b < 0x80) return 1;
        uint256 n;
        uint8 lo = 0x80;
        uint8 hi = 0xbf;
        if (b >= 0xc2 && b <= 0xdf) {
            n = 2;
        } else if (b >= 0xe0 && b <= 0xef) {
            n = 3;
            if (b == 0xe0) lo = 0xa0;
            if (b == 0xed) hi = 0x9f;
        } else if (b >= 0xf0 && b <= 0xf4) {
            n = 4;
            if (b == 0xf0) lo = 0x90;
            if (b == 0xf4) hi = 0x8f;
        } else {
            return 0;
        }
        if (i + n > s.length) return 0;
        uint8 c = uint8(s[i + 1]);
        if (c < lo || c > hi) return 0;
        for (uint256 k = 2; k < n; ++k) {
            c = uint8(s[i + k]);
            if (c < 0x80 || c > 0xbf) return 0;
        }
        return n;
    }

    /// @dev Decimal string of `n` with a comma every three integer digits.
    function _commas(uint256 n) private pure returns (string memory) {
        bytes memory b = bytes(n.toString());
        uint256 len = b.length;
        uint256 commas = (len - 1) / 3;
        if (commas == 0) return string(b);
        bytes memory r = new bytes(len + commas);
        uint256 j = r.length;
        for (uint256 i = 0; i < len; ++i) {
            if (i > 0 && i % 3 == 0) r[--j] = ",";
            r[--j] = b[len - 1 - i];
        }
        return string(r);
    }

    /// @dev Two-digit zero-padded string for `x < 100`.
    function _two(uint256 x) private pure returns (string memory) {
        return x < 10 ? string.concat("0", x.toString()) : x.toString();
    }
}

/// @title DescriptorArt
/// @notice Holds the static Envelop watermark for {WalletPositionDescriptor}. The descriptor deploys it
/// from its constructor and reads it per render: ~5 KB of SVG paths live here instead of in the
/// descriptor's runtime code, which keeps that under EIP-170 with the task_055 pricing logic.
contract DescriptorArt {
    function logo() external pure returns (string memory) {
        return DescriptorLib.logo();
    }
}
