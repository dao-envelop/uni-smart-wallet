// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseLPManager} from "./BaseLPManager.sol";

/// @title StableLPManager
/// @notice The stable-pool LP manager: a thin {BaseLPManager} product for a configured set of
/// hookless stable pools (arbitrary pairs, no common quote). Fixed per-pool ranges set at
/// `initialize`, operator-driven allocation with no `amount*Max` cap (owed ≤ desired at the
/// on-chain price), and the indirect `withdrawTo` drain. All logic lives in {BaseLPManager}; this
/// subclass only supplies the product identity (oracle tag, symbol, names).
contract StableLPManager is BaseLPManager {
    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) BaseLPManager(poolManager_, treasury_) {}

    /// @inheritdoc BaseLPManager
    function ORACLE_TYPE() public pure override returns (uint256) {
        return 3000;
    }

    /// @notice The NFT symbol — the shared constant `"eStableLP"` for every clone.
    function symbol() public pure override returns (string memory) {
        return "eStableLP";
    }

    function _productName() internal pure override returns (string memory) {
        return "StableLPManager";
    }

    function _defaultName() internal pure override returns (bytes32) {
        return bytes32("Envelop LP Uniswap Manager");
    }
}
