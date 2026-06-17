// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice External token-URI renderer for the NFT-owned wallets. The wallet's `tokenURI`
/// delegates here so the (heavy) on-chain JSON/SVG rendering lives outside the wallet bytecode
/// (EIP-170). Modeled on Uniswap v4's `PositionManager → IPositionDescriptor` split.
interface IWalletDescriptor {
    /// @param wallet  The wallet/manager contract whose portfolio is being rendered.
    /// @param tokenId The singleton ownership token id (always `TOKEN_ID = 1`).
    function tokenURI(address wallet, uint256 tokenId) external view returns (string memory);
}
