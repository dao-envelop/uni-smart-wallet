// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DescriptorLibWrapper} from "./helpers/DescriptorLibWrapper.sol";

contract DescriptorLibTest is Test {
    DescriptorLibWrapper internal lib;

    function setUp() public {
        lib = new DescriptorLibWrapper();
    }

    // ────────── formatUsd ──────────

    function test_formatUsd_zero() public view {
        assertEq(lib.formatUsd(0), "0.00");
    }

    function test_formatUsd_wholeAndCents() public view {
        assertEq(lib.formatUsd(1e18), "1.00");
        assertEq(lib.formatUsd(1.5e18), "1.50");
        assertEq(lib.formatUsd(1.05e18), "1.05");
        assertEq(lib.formatUsd(0.99e18), "0.99");
    }

    function test_formatUsd_thousandsSeparators() public view {
        assertEq(lib.formatUsd(1_234e18), "1,234.00");
        assertEq(lib.formatUsd(1_234_567e18 + 0.89e18), "1,234,567.89");
        assertEq(lib.formatUsd(999e18), "999.00");
    }

    function test_formatUsd_roundsToCents() public view {
        // 1.239 ⇒ rounded half-up (task_055; it used to truncate to 1.23)
        assertEq(lib.formatUsd(1.239e18), "1.24");
        assertEq(lib.formatUsd(1.234e18), "1.23");
    }

    // ────────── tokenIcon ──────────

    function test_badgeKind_byAllowlistNotBySymbol() public view {
        assertEq(lib.badgeKind("USDC", false, true), 2, "allowlisted USDC");
        assertEq(lib.badgeKind("USDbC", false, true), 2, "bridged USDC family");
        assertEq(lib.badgeKind("USDT", false, true), 3, "USDT");
        assertEq(lib.badgeKind(unicode"USD₮0", false, true), 3, "USDT0 family");
        assertEq(lib.badgeKind("DAI", false, true), 4, "DAI");
        assertEq(lib.badgeKind("USDe", false, true), 5, "other stable: generic");
        assertEq(lib.badgeKind("USDC", false, false), 0, "a token merely named USDC: plain");
        assertEq(lib.badgeKind("WETH", true, false), 1, "native / WETH: ETH mark");
    }

    function test_tokenIcon_brandMarksAndTicker() public view {
        assertTrue(_contains(lib.tokenIcon("USDC", 2, 20, 100), "#2775CA"), "usdc brand");
        assertTrue(_contains(lib.tokenIcon("USDT", 3, 20, 100), "#26A17B"), "usdt brand");
        assertTrue(_contains(lib.tokenIcon("DAI", 4, 20, 100), "#F5AC37"), "dai brand");
        assertTrue(_contains(lib.tokenIcon("ETH", 1, 20, 100), "#627EEA"), "eth mark");
        string memory icon = lib.tokenIcon("MCK", 0, 20, 100);
        assertTrue(_contains(icon, "#6b7280"), "fallback color");
        assertTrue(_contains(icon, "translate(20 100)"), "anchored");
        assertTrue(_contains(icon, ">MCK</text>"), "ticker text");
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
