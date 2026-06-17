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

/// @notice Echoes back the bytes it receives. Used to verify executeEncodedTx round-trip data.
contract Echo {
    function ping(bytes calldata data) external pure returns (bytes calldata) {
        return data;
    }
}
