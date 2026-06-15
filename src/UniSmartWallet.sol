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

/// @title UniSmartWallet
/// @notice NFT-owned smart wallet with direct Uniswap V4 liquidity management. Auth
/// (singleton ownership NFT + operators) lives in {SingletonNFTOwned}; the V4 mechanics
/// (positions + swaps) live in {V4PositionManager}; asset custody comes from Envelop's
/// {SmartWallet}. This contract wires them together with a constructor + public,
/// access-controlled entry points.
contract UniSmartWallet is SingletonNFTOwned, SmartWallet, V4PositionManager {
    uint256 public constant ORACLE_TYPE = 2002;
    string public constant DEFAULT_BASE_URI = "https://api.envelop.is/uniwallet/";

    /// @dev Directly deployed (not a clone), so the PoolManager can stay immutable.
    IPoolManager public immutable POOL_MANAGER;

    // We use these events to be compatable with existing envelop oracle
    event EnvelopV2OracleType(uint256 indexed oracleType, string contractName);
    event EnvelopWrappedV2(address indexed creator, uint256 indexed wnftTokenId, bytes32 indexed rules, bytes data);

    constructor(IPoolManager poolManager_) ERC721("ERC721 Name", "ERC721 symbol") {
        POOL_MANAGER = poolManager_;
        allowedHooks[address(0)] = true;
        _mintSingleton(msg.sender);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
        // We use these events to be compatable with existing envelop oracle
        emit EnvelopV2OracleType(ORACLE_TYPE, type(UniSmartWallet).name);
        emit EnvelopWrappedV2(msg.sender, TOKEN_ID, 0x0000, "");
    }

    /// @dev Resolve the V4 PoolManager for the base layer.
    function _poolManager() internal view override returns (IPoolManager) {
        return POOL_MANAGER;
    }

    /// @notice Execute an arbitrary call from the wallet. Withdrawals are a special case
    /// (empty data ⇒ native send via parent's Address.sendValue; non-empty ⇒ functionCallWithValue).
    /// Restricted to the NFT owner — operators must not be able to drain capital.
    function executeEncodedTx(address target, uint256 value, bytes memory data)
        external
        onlyOwnerNFT
        returns (bytes memory)
    {
        return _executeEncodedTx(target, value, data);
    }

    function executeEncodedTxBatch(address[] calldata targets, uint256[] calldata values, bytes[] memory datas)
        external
        onlyOwnerNFT
        returns (bytes[] memory)
    {
        return _executeEncodedTxBatch(targets, values, datas);
    }

    // ────────── Hook policy (owner-gated setters over base storage) ──────────

    function setHookAllowed(address hook, bool allowed) external onlyOwnerNFT {
        allowedHooks[hook] = allowed;
        emit HookAllowed(hook, allowed);
    }

    function setHookRegistry(address registry) external onlyOwnerNFT {
        hookRegistry = registry;
        emit HookRegistrySet(registry);
    }

    // ────────── Position ops (owner-or-operator wrappers over base) ──────────

    /// @notice Open a concentrated-liquidity position. See {V4PositionManager-_openPosition}.
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
    }

    function closePosition(bytes32 salt) external onlyAuthorized nonReentrant {
        _closePosition(salt);
    }

    function decreasePosition(bytes32 salt, uint128 deltaLiquidity) external onlyAuthorized nonReentrant {
        _decreasePosition(salt, deltaLiquidity);
    }

    function pokePosition(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokePosition(salt);
    }

    // ────────── Views ──────────

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC1155Holder) returns (bool) {
        //TODO  add current contract interfaceinterfaceId == type(IERC721).interfaceId ||
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
