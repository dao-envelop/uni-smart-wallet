// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;
//import {SmartWallet} from "@envelop-v2/src/impl/SmartWallet.sol";
import "@envelop-v2/src/impl/SmartWallet.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookRegistry} from "./interfaces/IHookRegistry.sol";

contract UniSmartWallet is SmartWallet, ERC721, IUnlockCallback {
    uint256 public constant ORACLE_TYPE = 2002;
    uint256 public constant TOKEN_ID = 1;
    string public constant DEFAULT_BASE_URI = "https://api.envelop.is/uniwallet/";

    // ────────── Pool integration & position state ──────────

    IPoolManager public immutable POOL_MANAGER;

    enum Op {
        OPEN,
        CLOSE,
        DECREASE,
        POKE
    }

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 openedAt;
    }

    mapping(bytes32 => Position) public positions;
    bytes32[] public openSalts;

    /// @notice Local hook whitelist. Constructor seeds address(0)=true (hookless pools).
    mapping(address => bool) public allowedHooks;
    /// @notice Optional external IHookRegistry. Zero ⇒ registry check skipped.
    address public hookRegistry;

    // We use these events to be compatable with existing envelop oracle
    event EnvelopV2OracleType(uint256 indexed oracleType, string contractName);
    event EnvelopWrappedV2(address indexed creator, uint256 indexed wnftTokenId, bytes32 indexed rules, bytes data);

    event OperatorSet(address indexed operator, bool allowed);
    event HookAllowed(address indexed hook, bool allowed);
    event HookRegistrySet(address indexed registry);

    error SingletonAlreadyMinted();
    error SingletonBurnForbidden();
    error NotOwnerNFT();
    error NotAuthorized();
    error ZeroOperator();
    error NotPoolManager();
    error UnknownOp(uint8 op);
    error NotImplemented(Op op);

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

    constructor(IPoolManager poolManager_) ERC721("ERC721 Name", "ERC721 symbol") {
        POOL_MANAGER = poolManager_;
        allowedHooks[address(0)] = true;
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

    // ────────── Hook policy ──────────

    function setHookAllowed(address hook, bool allowed) external onlyOwnerNFT {
        allowedHooks[hook] = allowed;
        emit HookAllowed(hook, allowed);
    }

    function setHookRegistry(address registry) external onlyOwnerNFT {
        hookRegistry = registry;
        emit HookRegistrySet(registry);
    }

    /// @notice Hook is acceptable iff it's in the local whitelist AND
    /// (no registry configured OR the registry also approves it).
    function _isHookAllowed(address hook) internal view returns (bool) {
        if (!allowedHooks[hook]) return false;
        address reg = hookRegistry;
        if (reg == address(0)) return true;
        return IHookRegistry(reg).isAllowed(hook);
    }

    // ────────── Unlock callback (dispatcher skeleton) ──────────

    /// @notice Called by PoolManager after `unlock(...)`. Each op handler is filled in
    /// by later tasks (#4 openPosition, #5 close / decrease / poke).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (Op op, bytes memory payload) = abi.decode(data, (Op, bytes));
        if (op == Op.OPEN) return _handleOpen(payload);
        if (op == Op.CLOSE) return _handleClose(payload);
        if (op == Op.DECREASE) return _handleDecrease(payload);
        if (op == Op.POKE) return _handlePoke(payload);
        revert UnknownOp(uint8(op));
    }

    function _handleOpen(bytes memory) internal virtual returns (bytes memory) {
        revert NotImplemented(Op.OPEN);
    }

    function _handleClose(bytes memory) internal virtual returns (bytes memory) {
        revert NotImplemented(Op.CLOSE);
    }

    function _handleDecrease(bytes memory) internal virtual returns (bytes memory) {
        revert NotImplemented(Op.DECREASE);
    }

    function _handlePoke(bytes memory) internal virtual returns (bytes memory) {
        revert NotImplemented(Op.POKE);
    }

    // ────────── Views ──────────

    function positionOf(bytes32 salt) external view returns (Position memory) {
        return positions[salt];
    }

    function openPositionCount() external view returns (uint256) {
        return openSalts.length;
    }

    function ownerNFTHolder() external view returns (address) {
        return ownerOf(TOKEN_ID);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC1155Holder) returns (bool) {
        //TODO  add current contract interfaceinterfaceId == type(IERC721).interfaceId ||
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId
            || super.supportsInterface(interfaceId);
    }
}
