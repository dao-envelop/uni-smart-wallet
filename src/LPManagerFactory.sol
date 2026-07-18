// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title LPManagerFactory
/// @notice Universal factory for the NFT-owned LP managers built on `BaseLPManager`
/// (`StableLPManager`, `VolatileLPManager`, and future products): clones any **allowlisted**
/// implementation as an EIP-1167 minimal proxy at a deterministic (CREATE2) address, then forwards
/// **product-specific `initialize` calldata** atomically in the same transaction.
///
/// Products declare their own `InitParams` (Stable carries per-pool ranges, Volatile is keys-only), so
/// their `initialize` selectors differ and one typed call cannot serve both. The caller ABI-encodes the
/// product's `initialize(InitParams)` off-chain and passes it as `initData`; the factory stays
/// product-agnostic. Modeled on Envelop's `EnvelopWNFTFactory` clone pattern (previously `StableLPFactory`).
///
/// @dev Safety rests on three properties: (1) the `implementation` must be on the owner-curated
/// allowlist — the clone emits Envelop oracle events (`EnvelopV2OracleType`/`EnvelopWrappedV2`) as this
/// trusted factory, so arbitrary bytecode must not be clonable through it; (2) clone + `initialize`
/// happen atomically, closing the classic clone-initializer front-run window; (3) a post-init check
/// that the singleton ownership NFT landed on `expectedOwner`, catching an `initData` that "succeeds"
/// without actually initializing (which would otherwise leave a hijackable deterministic clone) or that
/// initializes to the wrong owner. No reentrancy guard: implementations are allowlisted+trusted and
/// `initialize` moves no external value.
contract LPManagerFactory is Ownable {
    using Clones for address;

    /// @dev The singleton ownership token id minted by every manager (mirrors
    /// `SingletonNFTOwned.TOKEN_ID = 1`); used for the post-init owner check.
    uint256 private constant TOKEN_ID = 1;

    /// @notice Whether an implementation is blessed for cloning (owner-curated).
    mapping(address => bool) public isImplementation;

    /// @notice Per-owner deployment counter, feeding the CREATE2 salt.
    mapping(address => uint256) public nonce;

    /// @notice Emitted when an implementation is added to / removed from the allowlist.
    /// @param implementation The implementation contract.
    /// @param allowed True if now clonable, false if revoked.
    event ImplementationSet(address indexed implementation, bool allowed);

    /// @notice Emitted when a new manager clone is created and initialized.
    /// @param manager The deployed clone address.
    /// @param implementation The implementation cloned.
    /// @param owner The manager owner (singleton NFT holder).
    /// @param nonce The per-owner deployment index used in the CREATE2 salt.
    event ManagerCreated(address indexed manager, address indexed implementation, address indexed owner, uint256 nonce);

    error ZeroImplementation();
    error NotImplementation(address implementation);
    error ZeroOwner();
    error InitFailed();
    error OwnerMismatch(address expected, address actual);

    /// @notice Deploy the factory owned by `owner_` with an initial allowlist of implementations.
    /// @param owner_ The factory admin that may edit the allowlist (non-zero, enforced by `Ownable`).
    /// @param impls Implementations blessed for cloning at deploy (each non-zero).
    constructor(address owner_, address[] memory impls) Ownable(owner_) {
        for (uint256 i = 0; i < impls.length; ++i) {
            if (impls[i] == address(0)) revert ZeroImplementation();
            isImplementation[impls[i]] = true;
            emit ImplementationSet(impls[i], true);
        }
    }

    /// @notice Add or remove an implementation from the clonable allowlist.
    /// @param implementation The implementation contract (non-zero).
    /// @param allowed True to bless, false to revoke.
    function setImplementation(address implementation, bool allowed) external onlyOwner {
        if (implementation == address(0)) revert ZeroImplementation();
        isImplementation[implementation] = allowed;
        emit ImplementationSet(implementation, allowed);
    }

    /// @notice Clone `implementation` for `expectedOwner` and initialize it atomically with `initData`.
    /// The singleton NFT is minted to `expectedOwner` inside `initialize`; this factory verifies it.
    /// @param implementation The allowlisted manager implementation to clone.
    /// @param expectedOwner The intended manager owner (receives the singleton NFT). Must match what
    /// `initData` initializes; a mismatch reverts `OwnerMismatch`.
    /// @param initData ABI-encoded product-specific `initialize(InitParams)` call (built off-chain).
    /// @return manager The deployed, initialized clone address.
    function createManager(address implementation, address expectedOwner, bytes calldata initData)
        external
        returns (address manager)
    {
        if (!isImplementation[implementation]) revert NotImplementation(implementation);
        if (expectedOwner == address(0)) revert ZeroOwner();

        uint256 n = nonce[expectedOwner]++;
        bytes32 salt = keccak256(abi.encode(expectedOwner, implementation, n));
        manager = implementation.cloneDeterministic(salt);

        (bool ok, bytes memory ret) = manager.call(initData);
        if (!ok) {
            // Bubble the product's own revert (e.g. `HookNotAllowed`, `NoPools`) for a transparent
            // failure; fall back to `InitFailed` when the clone reverted without a reason (e.g. wrong
            // selector) so an empty revert isn't silently swallowed.
            if (ret.length == 0) revert InitFailed();
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        // Post-init guard: a successful-but-non-initializing call would leave a hijackable clone at a
        // known deterministic address, and a wrong-owner initData must not pass silently.
        address actual = IERC721(manager).ownerOf(TOKEN_ID);
        if (actual != expectedOwner) revert OwnerMismatch(expectedOwner, actual);

        emit ManagerCreated(manager, implementation, expectedOwner, n);
    }

    /// @notice The address `createManager` will produce for `(implementation, owner_, nonce_)`.
    /// @param implementation The implementation to clone (address is part of the EIP-1167 initcode).
    /// @param owner_ The prospective manager owner.
    /// @param nonce_ The deployment index to predict for (current value is in `nonce(owner_)`).
    /// @return The deterministic CREATE2 clone address.
    function predictManagerAddress(address implementation, address owner_, uint256 nonce_)
        external
        view
        returns (address)
    {
        return implementation.predictDeterministicAddress(keccak256(abi.encode(owner_, implementation, nonce_)));
    }
}
