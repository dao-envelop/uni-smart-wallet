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
    event EnvelopWrappedV2(
    	address indexed creator, 
    	uint256 indexed wnftTokenId, 
    	bytes32 indexed rules, 
    	bytes data
    );

    constructor(address _poolManager) 
        ERC721("ERC721 Name", "ERC721 symbol")
    {
    	_mint(msg.sender, TOKEN_ID);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
        // We use these events to be compatable with existing envelop oracle
        emit EnvelopV2OracleType(ORACLE_TYPE, type(UniSmartWallet).name);
        emit EnvelopWrappedV2(msg.sender,TOKEN_ID,0x0000,"");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, ERC1155Holder)
        returns (bool)
    {
        //TODO  add current contract interfaceinterfaceId == type(IERC721).interfaceId ||
        return 
            interfaceId == type(IERC721).interfaceId || 
            interfaceId == type(IERC721Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
