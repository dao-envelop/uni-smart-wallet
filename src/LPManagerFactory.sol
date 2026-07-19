// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @dev Minimal view surface of a `BaseLPManager` clone that the factory queries post-init (instead of
/// hard-coding the singleton token id / oracle type): the manager is the single source of truth.
interface IEnvelopManager {
    function TOKEN_ID() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function ORACLE_TYPE() external view returns (uint256);
}

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

    /// @notice Whether an implementation is blessed for cloning (owner-curated).
    mapping(address => bool) public isImplementation;

    /// @notice Per-owner deployment counter, feeding the CREATE2 salt.
    mapping(address => uint256) public nonce;

    /// @notice Emitted when an implementation is added to / removed from the allowlist.
    /// @param implementation The implementation contract.
    /// @param allowed True if now clonable, false if revoked.
    event ImplementationSet(address indexed implementation, bool allowed);

    /// @notice Emitted when a new manager clone is created and initialized (Envelop-ecosystem indexing).
    /// @param proxy The deployed clone (EIP-1167 proxy) address.
    /// @param implementation The implementation cloned.
    /// @param envelopOracleType The manager's Envelop oracle type tag (queried from `ORACLE_TYPE()`).
    event EnvelopV2Deployment(address indexed proxy, address indexed implementation, uint256 envelopOracleType);
    /// @notice Emitted when a creation call forwards native value to the new manager.
    /// @param manager The funded manager clone.
    /// @param value The amount of native token forwarded.
    event ManagerFunded(address indexed manager, uint256 value);

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

    /// @notice Clone `implementation` for `expectedOwner` at a deterministic (CREATE2) address and
    /// initialize it atomically with `initData`. The singleton NFT is minted to `expectedOwner` inside
    /// `initialize`; this factory verifies it. Any native `msg.value` is forwarded to the new manager.
    /// @dev The CREATE2 salt binds `keccak256(initData)`, so a front-runner cannot deploy a DIFFERENT
    /// config at a caller's predicted (pre-funded) address — a substituted `initData` yields a different
    /// address. Predict the address with {predictManagerAddress} using the SAME `initData`.
    /// @param implementation The allowlisted manager implementation to clone.
    /// @param expectedOwner The intended manager owner (receives the singleton NFT). Must match what
    /// `initData` initializes; a mismatch reverts `OwnerMismatch`.
    /// @param initData ABI-encoded product-specific `initialize(InitParams)` call (built off-chain).
    /// @return manager The deployed, initialized clone address.
    function createManager(address implementation, address expectedOwner, bytes calldata initData)
        external
        payable
        returns (address manager)
    {
        if (!isImplementation[implementation]) revert NotImplementation(implementation);
        if (expectedOwner == address(0)) revert ZeroOwner();

        uint256 n = nonce[expectedOwner]++;
        bytes32 salt = keccak256(abi.encode(expectedOwner, implementation, n, keccak256(initData)));
        manager = implementation.cloneDeterministic(salt);

        _initAndFund(manager, implementation, expectedOwner, initData);
    }

    /// @notice Like {createManager} but at a NON-deterministic (CREATE) address. Because the address is
    /// not caller-predictable, there is no pre-funded address for a front-runner to substitute config at —
    /// use this when the counterfactual-funding flow isn't needed. Does not consume the per-owner `nonce`.
    /// Any native `msg.value` is forwarded to the new manager.
    /// @param implementation The allowlisted manager implementation to clone.
    /// @param expectedOwner The intended manager owner (receives the singleton NFT).
    /// @param initData ABI-encoded product-specific `initialize(InitParams)` call.
    /// @return manager The deployed, initialized clone address.
    function createManagerNondeterministic(address implementation, address expectedOwner, bytes calldata initData)
        external
        payable
        returns (address manager)
    {
        if (!isImplementation[implementation]) revert NotImplementation(implementation);
        if (expectedOwner == address(0)) revert ZeroOwner();

        manager = implementation.clone();

        _initAndFund(manager, implementation, expectedOwner, initData);
    }

    /// @dev Atomically initialize a freshly-cloned `manager` with `initData`, verify the singleton NFT
    /// landed on `expectedOwner`, forward any `msg.value`, and emit. Shared by both create entry points.
    /// The singleton token id and oracle type are queried from the manager (the source of truth), not
    /// hard-coded here.
    function _initAndFund(address manager, address implementation, address expectedOwner, bytes calldata initData)
        internal
    {
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

        // Post-init guard: query the manager for its singleton token id and verify ownership landed on
        // `expectedOwner`. A successful-but-non-initializing call (nothing minted) makes `ownerOf` revert;
        // a wrong-owner initData reverts `OwnerMismatch`.
        IEnvelopManager m = IEnvelopManager(manager);
        address actual = m.ownerOf(m.TOKEN_ID());
        if (actual != expectedOwner) revert OwnerMismatch(expectedOwner, actual);

        // Forward any native value to the (validated) manager's `receive()`. Atomic: a failed send reverts
        // the whole creation, so no ETH is ever stranded.
        if (msg.value > 0) {
            Address.sendValue(payable(manager), msg.value);
            emit ManagerFunded(manager, msg.value);
        }

        emit EnvelopV2Deployment(manager, implementation, m.ORACLE_TYPE());
    }

    /// @notice The address `createManager` will produce for `(implementation, owner_, nonce_, initData)`.
    /// @dev Must be called with the SAME `initData` that will be passed to `createManager`, since the salt
    /// binds `keccak256(initData)`. Note the per-owner `nonce` is still advanceable by anyone (a valid
    /// `createManager` for `owner_` bumps it), which shifts this predicted address; to fund a new manager
    /// atomically without relying on counterfactual pre-funding, prefer `createManager{value: …}` (or
    /// {createManagerNondeterministic}), which forward native value to the manager on creation.
    /// @param implementation The implementation to clone (address is part of the EIP-1167 initcode).
    /// @param owner_ The prospective manager owner.
    /// @param nonce_ The deployment index to predict for (current value is in `nonce(owner_)`).
    /// @param initData The exact `initialize(InitParams)` calldata the deployment will use.
    /// @return The deterministic CREATE2 clone address.
    function predictManagerAddress(address implementation, address owner_, uint256 nonce_, bytes calldata initData)
        external
        view
        returns (address)
    {
        return implementation.predictDeterministicAddress(
            keccak256(abi.encode(owner_, implementation, nonce_, keccak256(initData)))
        );
    }
}
