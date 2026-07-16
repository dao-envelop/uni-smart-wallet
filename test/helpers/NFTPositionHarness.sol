// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SingletonNFTOwned} from "../../src/abstract/SingletonNFTOwned.sol";
import {V4PositionOpsHarness} from "./V4PositionOpsHarness.sol";
import {IWalletDescriptor} from "../../src/interfaces/IWalletDescriptor.sol";

/// @notice Test-only NFT-owned V4 position manager. Replaces the (removed) UniSmartWallet as the
/// shared scaffolding vehicle for the descriptor / lens / PositionState suites: it wires
/// {SingletonNFTOwned} auth + operators to the {V4PositionManager} mechanics and a pluggable
/// descriptor, without the Envelop SmartWallet custody layer. Position entry points mirror the old
/// wallet's surface (openPosition / closePosition / decreasePosition / pokePosition + descriptor +
/// tokenURI) so the tests read the same.
contract NFTPositionHarness is SingletonNFTOwned, V4PositionOpsHarness {
    /// @notice External on-chain metadata renderer for `tokenURI`. Zero ⇒ `tokenURI` returns "".
    address public positionDescriptor;

    constructor(IPoolManager poolManager_) ERC721("Envelop NFT Position", "eNFTP") V4PositionOpsHarness(poolManager_) {
        _mintSingleton(msg.sender);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

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

    function closePosition(bytes32 salt) external onlyAuthorized nonReentrant {
        _closePosition(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function decreasePosition(bytes32 salt, uint128 deltaLiquidity) external onlyAuthorized nonReentrant {
        _decreasePosition(salt, deltaLiquidity);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function pokePosition(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokePosition(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function setPositionDescriptor(address descriptor) external onlyOwnerNFT {
        positionDescriptor = descriptor;
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        address descriptor = positionDescriptor;
        if (descriptor == address(0)) return "";
        return IWalletDescriptor(descriptor).tokenURI(address(this), id);
    }

    /// @notice ERC-165: ERC-721 (+ Metadata) and ERC-4906.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == bytes4(0x49064906) // ERC-4906 (metadata update)
            || super.supportsInterface(interfaceId);
    }
}
