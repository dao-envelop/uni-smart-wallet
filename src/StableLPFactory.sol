// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StableLPManager} from "./StableLPManager.sol";

/// @title StableLPFactory
/// @notice Deploys {StableLPManager} instances as EIP-1167 minimal-proxy clones with a
/// deterministic (CREATE2) address per (owner, nonce), then forwards `initialize`.
/// Modeled on Envelop's `EnvelopWNFTFactory` clone pattern.
contract StableLPFactory {
    /// @notice The trusted StableLPManager implementation cloned for every manager.
    address public immutable implementation;

    /// @notice Per-owner deployment counter, feeding the CREATE2 salt.
    mapping(address => uint256) public nonce;

    /// @notice Emitted when a new manager clone is created and initialized.
    /// @param manager The deployed clone address.
    /// @param owner The manager owner (singleton NFT holder).
    /// @param nonce The per-owner deployment index used in the CREATE2 salt.
    event StableLPManagerCreated(address indexed manager, address indexed owner, uint256 nonce);

    error ZeroImplementation();

    /// @notice Deploy the factory bound to a fixed manager implementation.
    /// @param implementation_ The {StableLPManager} implementation cloned for every manager (non-zero).
    constructor(address implementation_) {
        if (implementation_ == address(0)) revert ZeroImplementation();
        implementation = implementation_;
    }

    /// @notice Clone a new manager for `p.owner` and initialize it atomically. The singleton NFT is
    /// minted to `p.owner` inside `initialize`.
    /// @param p Init parameters forwarded to {StableLPManager-initialize} (owner, name, pools).
    /// @return manager The deployed, initialized clone address.
    function createManager(StableLPManager.InitParams calldata p) external returns (address manager) {
        uint256 n = nonce[p.owner]++;
        bytes32 salt = keccak256(abi.encode(p.owner, n));
        manager = Clones.cloneDeterministic(implementation, salt);
        StableLPManager(payable(manager)).initialize(p);
        emit StableLPManagerCreated(manager, p.owner, n);
    }

    /// @notice The address `createManager` will produce for `owner` at a given `nonce`.
    /// @param owner The prospective manager owner.
    /// @param nonce_ The deployment index to predict for (current value is in `nonce(owner)`).
    /// @return The deterministic CREATE2 clone address.
    function predictManagerAddress(address owner, uint256 nonce_) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, keccak256(abi.encode(owner, nonce_)));
    }
}
