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
    /// @notice Id of the single, non-burnable ownership NFT. Its holder controls the contract.
    uint256 public constant TOKEN_ID = 1;

    bool private _singletonMinted;

    /// @notice Whether an address is currently an authorized operator (owner-delegated, can drive
    /// position ops but cannot withdraw). Auto-cleared on ownership transfer.
    mapping(address => bool) public operators;
    /// @dev Active operators only. Kept compact via swap-and-pop on disable so the per-transfer
    /// `_clearOperators` loop stays bounded (can't be grown into a transfer-bricking gas bomb).
    address[] internal _operatorList;
    /// @dev 1-based index into `_operatorList` (0 ⇒ not present). Enables O(1) splice.
    mapping(address => uint256) internal _operatorIndexPlusOne;

    /// @notice Emitted when an operator is enabled or disabled (also for each operator auto-cleared
    /// on an ownership transfer).
    /// @param operator The operator address.
    /// @param allowed True when enabled, false when disabled/cleared.
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
    /// @param to Recipient of the singleton ownership NFT.
    function _mintSingleton(address to) internal {
        _mint(to, TOKEN_ID);
        _singletonMinted = true;
    }

    /// @notice NFT-owner delegates operational rights to a bot without surrendering custody.
    /// Operators can drive position ops but cannot withdraw funds. Owner-only.
    /// @param op The operator address to enable or disable.
    /// @param allowed True to grant operator rights, false to revoke them.
    function setOperator(address op, bool allowed) external onlyOwnerNFT {
        if (op == address(0)) revert ZeroOperator();
        if (allowed) {
            if (!operators[op]) {
                operators[op] = true;
                _operatorList.push(op);
                _operatorIndexPlusOne[op] = _operatorList.length;
            }
        } else {
            if (operators[op]) {
                operators[op] = false;
                _spliceOperator(op);
            }
        }
        emit OperatorSet(op, allowed);
    }

    /// @dev O(1) swap-and-pop removal of `op` from `_operatorList` (mirrors `_removeSalt`).
    /// @param op The operator to splice out of the active list.
    function _spliceOperator(address op) private {
        uint256 idxPlusOne = _operatorIndexPlusOne[op];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = _operatorList.length - 1;
        if (idx != lastIdx) {
            address last = _operatorList[lastIdx];
            _operatorList[idx] = last;
            _operatorIndexPlusOne[last] = idx + 1;
        }
        _operatorList.pop();
        delete _operatorIndexPlusOne[op];
    }

    /// @dev Enforces the singleton invariant and auto-clears operators on ownership transfer.
    /// Post-constructor mints revert; burns of any tokenId revert (singleton must persist).
    /// @param to New holder (zero ⇒ burn, which reverts).
    /// @param tokenId Token being moved (only the singleton exists).
    /// @param auth Address authorizing the transfer (per OZ ERC-721).
    /// @return The previous owner (zero on the initial mint).
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

    /// @dev `_operatorList` holds only ACTIVE operators (disable splices out), so this loop is
    /// bounded by the live operator count, not by historical churn.
    function _clearOperators() internal {
        uint256 n = _operatorList.length;
        for (uint256 i = 0; i < n; ++i) {
            address op = _operatorList[i];
            operators[op] = false;
            delete _operatorIndexPlusOne[op];
            emit OperatorSet(op, false);
        }
        delete _operatorList;
    }
}
