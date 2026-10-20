// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {NFTPositionHarness} from "./NFTPositionHarness.sol";

/// @notice {NFTPositionHarness} with a settable `name()` (escaping / UTF-8 tests).
contract MetaNFTHarness is NFTPositionHarness {
    string private _nm = "Envelop NFT Position";

    constructor(IPoolManager pm) NFTPositionHarness(pm) {}

    function setName(string calldata n) external {
        _nm = n;
    }

    function name() public view override returns (string memory) {
        return _nm;
    }
}
