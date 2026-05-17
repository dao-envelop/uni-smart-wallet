// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Optional external view-contract consulted by UniSmartWallet's hook policy.
/// When set, isAllowed(hook) must return true (in addition to the local whitelist passing)
/// for openPosition to accept a pool whose PoolKey.hooks == hook.
interface IHookRegistry {
    function isAllowed(address hook) external view returns (bool);
}
