// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHookRegistry} from "../../src/interfaces/IHookRegistry.sol";

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

/// @notice Configurable IHookRegistry mock. Default reply is `defaultAllowed`,
/// per-address overrides via setAllowed.
contract MockHookRegistry is IHookRegistry {
    bool public defaultAllowed;
    mapping(address => bool) public overrideSet;
    mapping(address => bool) public overrideValue;

    constructor(bool defaultAllowed_) {
        defaultAllowed = defaultAllowed_;
    }

    function setAllowed(address hook, bool allowed) external {
        overrideSet[hook] = true;
        overrideValue[hook] = allowed;
    }

    function isAllowed(address hook) external view returns (bool) {
        if (overrideSet[hook]) return overrideValue[hook];
        return defaultAllowed;
    }
}
