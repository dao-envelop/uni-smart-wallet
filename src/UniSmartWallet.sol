// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;
//import {SmartWallet} from "@envelop-v2/src/impl/SmartWallet.sol";
import "@envelop-v2/src/impl/SmartWallet.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC4906.sol";

contract UniSmartWallet is SmartWallet, ERC721 {
    uint256 public constant ORACLE_TYPE = 2002;
    uint256 public constant TOKEN_ID = 1;
    string public constant DEFAULT_BASE_URI = "https://api.envelop.is/uniwallet/";

    // We use these events to be compatable with existing envelop oracle
    event EnvelopV2OracleType(uint256 indexed oracleType, string contractName);
    event EnvelopWrappedV2(address indexed creator, uint256 indexed wnftTokenId, bytes32 indexed rules, bytes data);

    event OperatorSet(address indexed operator, bool allowed);

    error SingletonAlreadyMinted();
    error SingletonBurnForbidden();
    error NotOwnerNFT();
    error NotAuthorized();
    error ZeroOperator();

    bool private _singletonMinted;

    mapping(address => bool) public operators;
    address[] internal _operatorList;

    modifier onlyOwnerNFT() {
        if (ownerOf(TOKEN_ID) != msg.sender) revert NotOwnerNFT();
        _;
    }

    modifier onlyAuthorized() {
        if (ownerOf(TOKEN_ID) != msg.sender && !operators[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor(address _poolManager) ERC721("ERC721 Name", "ERC721 symbol") {
        _mint(msg.sender, TOKEN_ID);
        _singletonMinted = true;
        emit IERC4906.MetadataUpdate(TOKEN_ID);
        // We use these events to be compatable with existing envelop oracle
        emit EnvelopV2OracleType(ORACLE_TYPE, type(UniSmartWallet).name);
        emit EnvelopWrappedV2(msg.sender, TOKEN_ID, 0x0000, "");
    }

    /// @notice NFT-owner delegates operational rights to a bot without surrendering custody.
    /// Operators can drive position ops once those land in later tasks; they cannot withdraw funds.
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

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC1155Holder) returns (bool) {
        //TODO  add current contract interfaceinterfaceId == type(IERC721).interfaceId ||
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
