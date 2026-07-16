// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseLPManager} from "./BaseLPManager.sol";

/// @title VolatileLPManager
/// @notice {BaseLPManager} product for arbitrary (volatile) asset pairs. Reuses the base clone/init,
/// managed-currency union, protocol-fee skim, indirect `withdrawTo` drain, and settlement primitives,
/// and adds what volatile pairs need over the stable model: per-call tick ranges, salt-keyed
/// multi-position (several ranges per pool), `amount*Max` + `minAmountOut` slippage caps, and a
/// single-call `recenter`. Its allocate/recenter ops are added via `_dispatchExtraOp` (op codes ≥ 7)
/// so the base dispatcher is reused unchanged.
/// @dev Volatile-specific ops/structs land in the next steps of task_026; this defines the product
/// identity and the subclass shell.
contract VolatileLPManager is BaseLPManager {
    // Volatile op codes extend the base set (POKE + ALLOCATE/WITHDRAW_TO/REINVEST = 3–6); ≥ 7 here.
    uint8 internal constant OP_ALLOCATE_V = 7;
    uint8 internal constant OP_RECENTER = 8;

    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) BaseLPManager(poolManager_, treasury_) {}

    /// @inheritdoc BaseLPManager
    function ORACLE_TYPE() public pure override returns (uint256) {
        return 3001;
    }

    /// @notice The NFT symbol — the shared constant `"eVolLP"` for every clone.
    function symbol() public pure override returns (string memory) {
        return "eVolLP";
    }

    function _productName() internal pure override returns (string memory) {
        return "VolatileLPManager";
    }

    function _defaultName() internal pure override returns (bytes32) {
        return bytes32("Envelop Volatile LP Manager");
    }
}
