// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DescriptorLib} from "../../src/lib/DescriptorLib.sol";

/// @notice External boundary over {DescriptorLib} so its `internal` (inlined) helpers can be
/// exercised directly — mirrors `PositionMathWrapper`.
contract DescriptorLibWrapper {
    function formatUsd(uint256 scaled1e18) external pure returns (string memory) {
        return DescriptorLib.formatUsd(scaled1e18);
    }

    function formatPercentBps(uint256 bps) external pure returns (string memory) {
        return DescriptorLib.formatPercentBps(bps);
    }

    function tokenIcon(string memory sym, uint256 x, uint256 y) external pure returns (string memory) {
        return DescriptorLib.tokenIcon(sym, x, y);
    }
}
