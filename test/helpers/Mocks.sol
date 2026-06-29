// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal ERC-20 with public mint, for tests that need a token balance.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock ERC-20 with a toggleable fee-on-transfer (basis points), skimmed to a sink on every
/// non-mint/non-burn transfer. `feeBps` starts at 0 (behaves like a plain token) and can be flipped
/// on later to model a "stable" that activates a transfer fee after positions already exist (e.g. a
/// USDT-style configurable fee). Used by the H-2 PoC to show the manager's settle/delivery accounting
/// assumes `received == sent`.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public feeBps; // out of 10_000
    address public immutable feeSink;

    constructor() ERC20("FeeOnTransfer", "FOT") {
        feeSink = address(0xF0F0);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    /// @dev Apply the fee only on real transfers (mint `from==0` / burn `to==0` are exempt).
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, feeSink, fee);
    }
}

/// @notice Echoes back the bytes it receives. Used to verify executeEncodedTx round-trip data.
contract Echo {
    function ping(bytes calldata data) external pure returns (bytes calldata) {
        return data;
    }
}
