// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title SingletonNFTOwned
/// @notice Authorization root shared by the V4 product contracts: control over the
/// contract is vested in the holder of a single, non-burnable ERC-721 token
/// (`TOKEN_ID = 1`). Transferring that one NFT atomically hands over control and
/// auto-clears all operator delegations. There is no separate admin/owner role —
/// the NFT *is* the auth root.
/// @dev Auth-only and deployment-agnostic: the actual mint is performed by the
/// subclass at the right moment via {_mintSingleton} (constructor for a directly
/// deployed contract, `initialize` for a clone).
abstract contract SingletonNFTOwned is ERC721 {
    uint256 public constant TOKEN_ID = 1;

    bool private _singletonMinted;

    mapping(address => bool) public operators;
    address[] internal _operatorList;

    event OperatorSet(address indexed operator, bool allowed);

    error SingletonAlreadyMinted();
    error SingletonBurnForbidden();
    error NotOwnerNFT();
    error NotAuthorized();
    error ZeroOperator();

    /// @notice Gates everything that can move capital out: only the NFT holder.
    modifier onlyOwnerNFT() {
        if (ownerOf(TOKEN_ID) != msg.sender) revert NotOwnerNFT();
        _;
    }

    /// @notice Owner-or-operator. Gates operational actions that keep value inside
    /// the contract (e.g. position management) so a bot can act without owner signing.
    modifier onlyAuthorized() {
        if (ownerOf(TOKEN_ID) != msg.sender && !operators[msg.sender]) revert NotAuthorized();
        _;
    }

    /// @dev Mint the singleton ownership token. Call exactly once from the subclass
    /// init path. The `_update` guard below relies on `_singletonMinted` being set
    /// only *after* this first mint completes.
    function _mintSingleton(address to) internal {
        _mint(to, TOKEN_ID);
        _singletonMinted = true;
    }

    /// @notice NFT-owner delegates operational rights to a bot without surrendering custody.
    /// Operators can drive position ops but cannot withdraw funds.
    function setOperator(address op, bool allowed) external onlyOwnerNFT {
        if (op == address(0)) revert ZeroOperator();
        if (allowed) {
            if (!operators[op]) {
                operators[op] = true;
                _operatorList.push(op);
            }
        } else {
            if (operators[op]) {
                operators[op] = false;
            }
        }
        emit OperatorSet(op, allowed);
    }

    /// @dev Enforces the singleton invariant and auto-clears operators on ownership transfer.
    /// Post-constructor mints revert; burns of any tokenId revert (singleton must persist).
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address previousOwner = super._update(to, tokenId, auth);
        if (previousOwner == address(0)) {
            if (_singletonMinted) revert SingletonAlreadyMinted();
        } else if (to == address(0)) {
            revert SingletonBurnForbidden();
        } else {
            _clearOperators();
        }
        return previousOwner;
    }

    function _clearOperators() internal {
        uint256 n = _operatorList.length;
        for (uint256 i = 0; i < n; ++i) {
            address op = _operatorList[i];
            if (operators[op]) {
                operators[op] = false;
                emit OperatorSet(op, false);
            }
        }
        delete _operatorList;
    }

    function ownerNFTHolder() external view returns (address) {
        return ownerOf(TOKEN_ID);
    }
}
