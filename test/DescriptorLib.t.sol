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

    function test_formatUsd_truncatesToCents() public view {
        // 1.239 ⇒ truncated, not rounded
        assertEq(lib.formatUsd(1.239e18), "1.23");
    }

    // ────────── formatPercentBps ──────────

    function test_formatPercentBps() public view {
        assertEq(lib.formatPercentBps(0), "0.00%");
        assertEq(lib.formatPercentBps(1234), "12.34%");
        assertEq(lib.formatPercentBps(5), "0.05%");
        assertEq(lib.formatPercentBps(100), "1.00%");
        assertEq(lib.formatPercentBps(10000), "100.00%");
    }

    // ────────── tokenIcon ──────────

    function test_tokenIcon_knownStableBrandColor() public view {
        assertTrue(_contains(lib.tokenIcon("USDC", 20, 100), "#2775CA"), "usdc brand");
        assertTrue(_contains(lib.tokenIcon("USDT", 20, 100), "#26A17B"), "usdt brand");
        assertTrue(_contains(lib.tokenIcon("DAI", 20, 100), "#F5AC37"), "dai brand");
    }

    function test_tokenIcon_unknownFallbackColorAndTicker() public view {
        string memory icon = lib.tokenIcon("MCK", 20, 100);
        assertTrue(_contains(icon, "#6b7280"), "fallback color");
        assertTrue(_contains(icon, "MCK"), "ticker text");
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
