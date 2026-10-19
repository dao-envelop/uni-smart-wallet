// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NFTPositionHarness} from "./NFTPositionHarness.sol";

/// @notice {NFTPositionHarness} with a settable `name()` (escaping / UTF-8 tests) and an optional
/// per-position fee clock `feesSince(salt)` — the hook the descriptor reads for an honest APR
/// (task_055). A zero clock reads as "absent", as on every v2.1 manager.
contract MetaNFTHarness is NFTPositionHarness {
    string private _nm = "Envelop NFT Position";
    mapping(bytes32 => uint256) public feesSince;

    constructor(IPoolManager pm) NFTPositionHarness(pm) {}

    function setName(string calldata n) external {
        _nm = n;
    }

    function setFeesSince(bytes32 salt, uint256 t) external {
        feesSince[salt] = t;
    }

    function name() public view override returns (string memory) {
        return _nm;
    }
}
