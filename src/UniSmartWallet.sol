// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;
//import {SmartWallet} from "@envelop-v2/src/impl/SmartWallet.sol";
import "@envelop-v2/src/impl/SmartWallet.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SingletonNFTOwned} from "./abstract/SingletonNFTOwned.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";

/// @title UniSmartWallet
/// @notice NFT-owned smart wallet with direct Uniswap V4 liquidity management. Auth
/// (singleton ownership NFT + operators) lives in {SingletonNFTOwned}; the V4 mechanics
/// (positions + swaps) live in {V4PositionManager}; asset custody comes from Envelop's
/// {SmartWallet}. This contract wires them together with a constructor + public,
/// access-controlled entry points.
contract UniSmartWallet is SingletonNFTOwned, SmartWallet, V4PositionManager {
    /// @notice Envelop V2 oracle type tag emitted at deploy for oracle indexing (constant `2002`).
    uint256 public constant ORACLE_TYPE = 2002;

    /// @notice External on-chain metadata renderer for `tokenURI`. Zero ⇒ `tokenURI` returns "".
    address public positionDescriptor;

    /// @notice Emitted once at deploy so existing Envelop V2 oracles can index this wallet.
    /// @param oracleType The Envelop oracle type tag (`ORACLE_TYPE` = 2002).
    /// @param contractName The contract's type name (`"UniSmartWallet"`).
    event EnvelopV2OracleType(uint256 indexed oracleType, string contractName);
    /// @notice Envelop-compatibility wrap event emitted once at deploy for the singleton token.
    /// @param creator The deployer (initial NFT holder).
    /// @param wnftTokenId The singleton ownership token id (`TOKEN_ID` = 1).
    /// @param rules Packed Envelop rules (unused here, `0x0000`).
    /// @param data Extra Envelop payload (empty here).
    event EnvelopWrappedV2(address indexed creator, uint256 indexed wnftTokenId, bytes32 indexed rules, bytes data);

    /// @notice Deploy the wallet, mint the singleton ownership NFT (`TOKEN_ID` = 1) to the deployer,
    /// and emit the Envelop oracle-compatibility events.
    /// @param poolManager_ The Uniswap V4 PoolManager this wallet routes liquidity through.
    constructor(IPoolManager poolManager_) ERC721("Envelop UniSmartWallet", "eUSW") V4PositionManager(poolManager_) {
        _mintSingleton(msg.sender);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
        // We use these events to be compatable with existing envelop oracle
        emit EnvelopV2OracleType(ORACLE_TYPE, type(UniSmartWallet).name);
        emit EnvelopWrappedV2(msg.sender, TOKEN_ID, 0x0000, "");
    }

    /// @notice Execute an arbitrary call from the wallet. Withdrawals are a special case
    /// (empty data ⇒ native send via parent's Address.sendValue; non-empty ⇒ functionCallWithValue).
    /// Restricted to the NFT owner — operators must not be able to drain capital.
    /// @param target Address to call (token, dApp, or recipient for a native send).
    /// @param value Native wei to forward with the call.
    /// @param data Calldata; empty ⇒ plain native transfer to `target`.
    /// @return The raw bytes returned by the call.
    function executeEncodedTx(address target, uint256 value, bytes memory data)
        external
        onlyOwnerNFT
        returns (bytes memory)
    {
        return _executeEncodedTx(target, value, data);
    }

    /// @notice Execute a batch of arbitrary calls from the wallet in one transaction. Owner-only.
    /// @param targets Addresses to call, one per batch element.
    /// @param values Native wei to forward per call (same length as `targets`).
    /// @param datas Calldata per call; an empty `datas[i]` ⇒ plain native transfer to `targets[i]`.
    /// @return The raw bytes returned by each call, in order.
    function executeEncodedTxBatch(address[] calldata targets, uint256[] calldata values, bytes[] memory datas)
        external
        onlyOwnerNFT
        returns (bytes[] memory)
    {
        return _executeEncodedTxBatch(targets, values, datas);
    }

    // ────────── Position ops (owner-or-operator wrappers over base) ──────────

    /// @notice Open a concentrated-liquidity position from the wallet's own balance. Owner-or-operator.
    /// Validates hook policy + pool existence + optional min pool liquidity, then mints liquidity and
    /// settles the owed amounts (capped by `amount0Max`/`amount1Max`). See {V4PositionManager-_openPosition}.
    /// @param key The Uniswap V4 pool to provide liquidity in (must be hookless).
    /// @param tickLower Lower tick of the range (multiple of the pool's tick spacing).
    /// @param tickUpper Upper tick of the range (multiple of the pool's tick spacing).
    /// @param liquidity Amount of liquidity to mint.
    /// @param salt Caller-chosen key identifying this position in the registry.
    /// @param minPoolLiquidity Optional floor on the pool's active liquidity (0 ⇒ no check).
    /// @param amount0Max Slippage cap on currency0 owed (revert if exceeded).
    /// @param amount1Max Slippage cap on currency1 owed (revert if exceeded).
    function openPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt,
        uint128 minPoolLiquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) external onlyAuthorized nonReentrant {
        _openPosition(key, tickLower, tickUpper, liquidity, salt, minPoolLiquidity, amount0Max, amount1Max);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice Fully close a position: withdraw all principal + accrued fees to the wallet and clear
    /// the registry entry. Owner-or-operator.
    /// @param salt The position key passed to {openPosition}.
    function closePosition(bytes32 salt) external onlyAuthorized nonReentrant {
        _closePosition(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice Reduce a position's liquidity by `deltaLiquidity`, taking the freed principal + fees to
    /// the wallet; the registry entry stays. Owner-or-operator.
    /// @param salt The position key passed to {openPosition}.
    /// @param deltaLiquidity Amount of liquidity to remove (must be ≤ the position's current liquidity).
    function decreasePosition(bytes32 salt, uint128 deltaLiquidity) external onlyAuthorized nonReentrant {
        _decreasePosition(salt, deltaLiquidity);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice Harvest accrued fees only (no principal change) to the wallet. Owner-or-operator.
    /// @param salt The position key passed to {openPosition}.
    function pokePosition(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokePosition(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    // ────────── Metadata ──────────

    /// @notice Set the external `tokenURI` renderer. Owner-only.
    /// @param descriptor The {IWalletDescriptor} to render `tokenURI`; the zero address ⇒ `tokenURI`
    /// returns an empty string.
    function setPositionDescriptor(address descriptor) external onlyOwnerNFT {
        positionDescriptor = descriptor;
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice On-chain metadata for the singleton ownership token. Delegates rendering to the
    /// configured {IWalletDescriptor}; returns "" if none is set (never reverts).
    /// @param id The token id (only the singleton `TOKEN_ID` = 1 exists).
    /// @return The descriptor's data-URI, or "" when no descriptor is configured.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        address descriptor = positionDescriptor;
        if (descriptor == address(0)) return "";
        return IWalletDescriptor(descriptor).tokenURI(address(this), id);
    }

    // ────────── Views ──────────

    /// @notice ERC-165 interface support, advertising ERC-721 (+ Metadata) and ERC-4906.
    /// @param interfaceId The ERC-165 interface identifier to query.
    /// @return True if the interface is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC1155Holder) returns (bool) {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId
            || interfaceId == bytes4(0x49064906) // ERC-4906 (metadata update)
            || super.supportsInterface(interfaceId);
    }
}
