// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DescriptorLib} from "../../src/lib/DescriptorLib.sol";

/// @notice External boundary over {DescriptorLib} so its `internal` (inlined) helpers can be
/// exercised directly — mirrors `PositionMathWrapper`.
contract DescriptorLibWrapper {
    function formatUsd(uint256 scaled1e18) external pure returns (string memory) {
        return DescriptorLib.formatUsd(scaled1e18);
    }

    function tokenIcon(string memory sym, uint8 kind, uint256 x, uint256 y) external pure returns (string memory) {
        return DescriptorLib.tokenIcon(sym, DescriptorLib.badge(kind), x, y);
    }

    function badgeKind(string memory sym, bool nativeEth, bool stable) external pure returns (uint8) {
        return DescriptorLib.badgeKind(sym, nativeEth, stable);
    }

    function clean(bytes memory s, uint256 maxLen, bool json) external pure returns (string memory) {
        return DescriptorLib.clean(s, maxLen, json);
    }

    function q0to1(uint256 a0, uint160 sp) external pure returns (uint256) {
        return DescriptorLib.q0to1(a0, sp);
    }

    function q1to0(uint256 a1, uint160 sp) external pure returns (uint256) {
        return DescriptorLib.q1to0(a1, sp);
    }
}
