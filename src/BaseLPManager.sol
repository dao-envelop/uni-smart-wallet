// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SingletonNFTOwned} from "./abstract/SingletonNFTOwned.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";

/// @title BaseLPManager
/// @notice Shared abstract core for the clone-deployed, NFT-owned LP managers. Holds the configured
/// hookless pool set (identity only) + managed-currency union, the init scaffolding, the protocol-fee
/// skim, currency settlement primitives, `tokenURI`/descriptor, the owner escape hatch, the unlock
/// dispatch shell, and the manager position store (`StoredPosition`, keyed by salt, reconstructing the
/// full `PoolKey` from the configured set on read). The liquidity model itself — allocate / withdraw /
/// reinvest / claimFees and the per-pool-vs-per-call range + slippage policy — lives in each product
/// subclass (`StableLPManager`, `VolatileLPManager`), which supplies its own `initialize` (with its
/// own range convention), routes its ops via `_dispatchExtraOp`, and supplies its identity
/// (`ORACLE_TYPE` / `symbol` / product name / default NFT name). This keeps each product carrying only
/// its own model, so both fit under EIP-170.
/// @dev Reuses {SingletonNFTOwned} (auth) and {V4PositionManager} (V4 mechanics). ERC20-only custody
/// (accepts native via `receive`, no NFT/ERC1155 holders) with a single batch escape hatch
/// (`executeEncodedTxBatch`). Deployed as an EIP-1167 clone; config is injected via one-shot init.
abstract contract BaseLPManager is SingletonNFTOwned, V4PositionManager {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Envelop V2 oracle type tag (product-specific), emitted at initialize for oracle indexing.
    function ORACLE_TYPE() public view virtual returns (uint256);
    /// @dev Product type name embedded in the `EnvelopV2OracleType` event (e.g. "StableLPManager").
    function _productName() internal pure virtual returns (string memory);
    /// @notice Upper bound on configured pools — caps allocate/settle loop costs.
    uint8 public constant MAX_POOLS = 8;
    /// @notice Protocol fee skimmed from every realized fee accrual, in basis points (10%).
    uint16 public constant PROTOCOL_FEE_BPS = 1000;
    /// @dev Fallback NFT name (product-specific) used when the init name is empty (`bytes32(0)`).
    function _defaultName() internal pure virtual returns (bytes32);

    // ────────── Config structs ──────────

    /// @notice A configured pool — identity only. Position ranges are NOT a pool-level attribute here:
    /// each product decides its range convention (Stable: fixed per-pool; Volatile: per-call).
    struct PoolConfig {
        PoolKey key;
    }

    /// @notice On-chain position record. Stores the pool by `poolId` (1 slot) rather than the full
    /// `PoolKey` (3 slots) — the key is reconstructed from the configured set in `positionOf`. For a
    /// `salt == poolId` product (Stable) `poolId` is redundant with the salt; for a multi-position
    /// product (Volatile, `salt ≠ poolId`) it is the only link from the salt to its pool.
    struct StoredPosition {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 openedAt;
    }

    // ────────── allocate structs ──────────

    /// @notice One pool action: optionally pre-swap inside the pool to balance the sides, then add
    /// liquidity with operator-sized desired amounts and slippage caps. Quote-agnostic — direction
    /// and amounts are fully specified by the operator off-chain.
    struct AllocLeg {
        PoolId poolId; // which configured pool this leg targets
        bool zeroForOne; // pre-swap direction (input side)
        uint256 swapAmountIn; // exactIn into the pool; 0 = no pre-swap
        uint160 swapPriceLimit; // sqrtPriceLimitX96 — slippage guard on the swap
        uint256 amount0Desired; // operator-sized add amounts (these bound the spend per side)
        uint256 amount1Desired;
        uint128 minLiquidity; // floor on minted L (slippage on the add)
    }

    // ────────── withdrawTo structs ──────────

    /// @notice One position (by salt) to pull liquidity from during `withdrawTo`. Salt-keyed for both
    /// products: Stable's `salt == poolId`, Volatile's salt is caller-chosen — either way the pool key
    /// and range are read from the stored position, not passed here.
    struct WithdrawStep {
        bytes32 salt; // the open position to pull from
        uint128 liquidityToPull; // modifyLiquidity(-L)
    }

    struct WithdrawSwap {
        PoolId poolId; // configured pool to swap in (key from `pools`)
        bool zeroForOne;
        int256 amountSpecified; // convert a freed leg into requestedCurrency (exactOut preferred)
        uint160 sqrtPriceLimitX96; // per-swap slippage guard
    }

    struct WithdrawToParams {
        address recipient;
        Currency requestedCurrency;
        uint256 amount; // exact amount delivered to recipient
        WithdrawStep[] pulls;
        WithdrawSwap[] swaps;
    }

    // ────────── State ──────────

    /// @notice The configured pools (fixed at init); identity only — ranges live per product.
    PoolConfig[] public pools;
    /// @notice 1-based index of a pool in `pools` keyed by its poolId (0 ⇒ not configured).
    mapping(PoolId => uint256) internal _poolIndexPlusOne;
    /// @notice Whether a currency is a managed stable (a currency of some configured pool).
    mapping(Currency => bool) public isManagedStable;
    /// @notice Enumerable union of all currencies across `pools` (for net settlement).
    Currency[] public managedStables;
    /// @notice The open position keyed by salt (zero-liquidity ⇒ no position).
    mapping(bytes32 => StoredPosition) internal _positions;
    bool private _initialized;
    bytes32 private _name; // per-clone NFT name, packed; set once at init

    /// @notice External on-chain metadata renderer for `tokenURI`. Zero ⇒ `tokenURI` returns "".
    address public positionDescriptor;

    /// @notice Protocol fee recipient. Immutable — set by the protocol at implementation deploy and
    /// shared by every clone; NOT owner-settable, so the fee can't be redirected away from the protocol.
    address public immutable PROTOCOL_TREASURY;

    // ────────── Events ──────────

    // Envelop oracle compatibility.
    /// @notice Emitted once at initialize so existing Envelop V2 oracles can index this manager.
    /// @param oracleType The Envelop oracle type tag (`ORACLE_TYPE`).
    /// @param contractName The contract name (e.g. `"StableLPManager"`).
    event EnvelopV2OracleType(uint256 indexed oracleType, string contractName);
    /// @notice Envelop-compatibility wrap event emitted once at initialize for the singleton token.
    /// @param creator The manager owner (initial NFT holder).
    /// @param wnftTokenId The singleton ownership token id (`TOKEN_ID` = 1).
    /// @param rules Packed Envelop rules (unused here, `0x0000`).
    /// @param data Extra Envelop payload (empty here).
    event EnvelopWrappedV2(address indexed creator, uint256 indexed wnftTokenId, bytes32 indexed rules, bytes data);

    /// @notice Emitted once when the clone is initialized.
    /// @param owner The manager owner (singleton NFT holder).
    /// @param poolManager The V4 PoolManager address.
    /// @param poolCount Number of configured pools.
    event Initialized(address indexed owner, address poolManager, uint256 poolCount);
    /// @notice Emitted after an `allocate`/`allocateFrom` deploys liquidity.
    /// @param legs Number of legs processed.
    event Allocated(uint256 legs);
    /// @notice Emitted when `withdrawTo` delivers a stable to a recipient.
    /// @param recipient Address that received the funds.
    /// @param stable The delivered currency.
    /// @param amount Amount delivered.
    event WithdrawnTo(address indexed recipient, Currency indexed stable, uint256 amount);
    /// @notice Emitted when `reinvest` compounds fees back into a position.
    /// @param salt The position key (`== poolId`).
    /// @param addedLiquidity Liquidity added by compounding.
    event Reinvested(bytes32 indexed salt, uint128 addedLiquidity);
    /// @notice Emitted for each protocol-fee skim taken as ERC-6909 claims to the treasury.
    /// @param currency The skimmed currency.
    /// @param amount The protocol-fee amount skimmed.
    event ProtocolFeeTaken(Currency indexed currency, uint256 amount);

    // ────────── Errors ──────────

    error AlreadyInitialized();
    error ZeroTreasury();
    error NoPools();
    error TooManyPools(uint256 n);
    error DuplicatePool(PoolId id);
    error NoLegs();
    error UnknownPool(PoolId id);
    error UnmanagedStable(Currency c);
    error AmountNotDelivered(uint256 got, uint256 want);
    error SwapSlippage(PoolId poolId);
    error MinLiquidityNotMet(uint128 got, uint128 min);
    error RecipientZero();
    error NotDeposited(Currency stable, uint256 have, uint256 want);
    error UnexpectedStableSpend(Currency c);
    error ZeroAmount();
    error ArrayLengthMismatch();

    /// @notice Deploy the implementation: set the shared immutables and lock the impl from being
    /// initialized. Clones (the actual managers) are created by a factory, not this constructor.
    /// @dev Sets the shared `POOL_MANAGER` immutable (in the base) and locks the implementation
    /// instance. Clones get fresh storage (`_initialized == false`), never run this constructor, but
    /// DO read the implementation's `POOL_MANAGER` immutable through delegatecall.
    /// @param poolManager_ The Uniswap V4 PoolManager shared by every clone.
    /// @param treasury_ The immutable protocol-fee recipient (non-zero; typically a {FeeRedeemer}).
    constructor(IPoolManager poolManager_, address treasury_) ERC721("", "") V4PositionManager(poolManager_) {
        if (treasury_ == address(0)) revert ZeroTreasury();
        PROTOCOL_TREASURY = treasury_;
        _initialized = true;
    }

    // ────────── Init scaffolding (used by each product's `initialize`) ──────────

    /// @dev Start the one-shot init: reverts on re-init, marks initialized, records the packed name.
    /// Called FIRST in a product's `initialize` so a double call reverts before any pool registration.
    /// @param name_ The packed NFT name (empty ⇒ product default).
    function _beginInit(bytes32 name_) internal {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _name = name_;
    }

    /// @dev Register one configured pool: hookless gate, dedup by poolId, push identity, and union its
    /// currencies into the managed-stable set. Ranges (if any) are the product's concern.
    /// @param key The pool to configure (must be hookless and not already configured).
    function _registerPool(PoolKey memory key) internal {
        if (address(key.hooks) != address(0)) revert HookNotAllowed(address(key.hooks));
        PoolId id = key.toId();
        if (_poolIndexPlusOne[id] != 0) revert DuplicatePool(id); // poolId is a position salt ⇒ must be unique
        pools.push(PoolConfig({key: key}));
        _poolIndexPlusOne[id] = pools.length; // 1-based
        _registerManaged(key.currency0);
        _registerManaged(key.currency1);
    }

    /// @dev Finish the one-shot init: optionally wire the `tokenURI` renderer, mint the singleton NFT
    /// to `owner_`, and emit the init/oracle events. Called LAST in a product's `initialize`.
    /// @param owner_ The manager owner (receives the singleton NFT).
    /// @param poolCount_ Number of configured pools (for the `Initialized` event).
    /// @param descriptor_ The default `tokenURI` renderer to set at init; zero ⇒ none (owner can set
    /// it later via `setPositionDescriptor`).
    function _finishInit(address owner_, uint256 poolCount_, address descriptor_) internal {
        if (descriptor_ != address(0)) positionDescriptor = descriptor_;
        _mintSingleton(owner_);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
        emit EnvelopV2OracleType(ORACLE_TYPE(), _productName());
        emit EnvelopWrappedV2(owner_, TOKEN_ID, 0x0000, "");
        emit Initialized(owner_, address(POOL_MANAGER), poolCount_);
    }

    /// @dev Add a currency to the managed-stable set (dedup via the mapping).
    function _registerManaged(Currency c) internal {
        if (!isManagedStable[c]) {
            isManagedStable[c] = true;
            managedStables.push(c);
        }
    }

    /// @notice The per-clone NFT name. Decodes the packed `_name` set at init; an empty name falls
    /// back to the product default.
    /// @return The manager's NFT name.
    // Clones don't run the ERC721 constructor, so derive name from packed storage; symbol is shared.
    function name() public view override returns (string memory) {
        bytes32 n = _name;
        if (n == bytes32(0)) n = _defaultName(); // unnamed clone ⇒ product default
        uint256 len;
        while (len < 32 && n[len] != 0) ++len;
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = n[i];
        }
        return string(b);
    }

    /// @notice The NFT symbol (product-specific; subclasses override).
    function symbol() public pure virtual override returns (string memory) {
        return "eLP";
    }

    /// @notice Set the external `tokenURI` renderer. Owner-only.
    /// @param descriptor The {IWalletDescriptor} to render `tokenURI`; the zero address ⇒ `tokenURI`
    /// returns an empty string.
    function setPositionDescriptor(address descriptor) external onlyOwnerNFT {
        positionDescriptor = descriptor;
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice On-chain metadata for the singleton ownership token. Delegates to the configured
    /// {IWalletDescriptor}; returns "" if none is set (never reverts).
    /// @param id The token id (only the singleton `TOKEN_ID` = 1 exists).
    /// @return The descriptor's data-URI, or "" when no descriptor is configured.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        address descriptor = positionDescriptor;
        if (descriptor == address(0)) return "";
        return IWalletDescriptor(descriptor).tokenURI(address(this), id);
    }

    /// @notice Accept native transfers (e.g. gas refunds / dust, or the native side of an ETH pool).
    /// @dev No NFT/ERC1155 custody.
    receive() external payable {}

    // ────────── Unlock dispatch ──────────

    /// @notice PoolManager unlock callback. The base defines no ops of its own — it decodes the
    /// leading op code and forwards to `_dispatchExtraOp`, which each product overrides to route its
    /// own ops (POKE/allocate/withdraw/recenter…) against the shared primitives. Reverts unless called
    /// by the PoolManager.
    /// @param data ABI-encoded `(uint8 op, bytes payload)` produced by the product before `unlock`.
    /// @return The product handler's return data.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        return _dispatchExtraOp(op, payload);
    }

    /// @dev Shared op code owned by the base (the indirect-drain path is product-agnostic). Products
    /// use codes ≥ 6 (Stable 4/6, Volatile 7/8), so 5 is reserved here and reached via `super`.
    uint8 internal constant OP_WITHDRAW_TO = 5;

    /// @dev Base handles the shared `withdrawTo` op; unknown codes fall through to the product override
    /// chain (each product `super`-calls here for codes it does not recognize).
    function _dispatchExtraOp(uint8 op, bytes memory payload) internal virtual override returns (bytes memory) {
        if (op == OP_WITHDRAW_TO) return _handleWithdrawTo(payload);
        return super._dispatchExtraOp(op, payload);
    }

    // ────────── withdrawTo (indirect drain, product-agnostic) ──────────

    /// @notice Deliver `p.amount` of `p.requestedCurrency` straight to `p.recipient` via the v4-native
    /// `take` (never landing on the manager's or owner's balance). Pull the named positions (by salt),
    /// convert freed legs via `p.swaps`, then take the requested amount. Owner-only — the drain primitive.
    /// @param p Withdraw plan: recipient, requested currency + amount, salt-keyed pulls, conversion swaps.
    function withdrawTo(WithdrawToParams calldata p) external onlyOwnerNFT nonReentrant {
        if (p.recipient == address(0)) revert RecipientZero();
        if (!isManagedStable[p.requestedCurrency]) revert UnmanagedStable(p.requestedCurrency);
        if (p.amount == 0) revert ZeroAmount();
        for (uint256 i = 0; i < p.pulls.length; ++i) {
            uint128 have = _positions[p.pulls[i].salt].liquidity;
            if (have == 0) revert UnknownPosition(p.pulls[i].salt);
            if (p.pulls[i].liquidityToPull > have) revert DeltaExceedsLiquidity(p.pulls[i].liquidityToPull, have);
        }
        POOL_MANAGER.unlock(abi.encode(OP_WITHDRAW_TO, abi.encode(p)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleWithdrawTo(bytes memory payload) internal returns (bytes memory) {
        WithdrawToParams memory p = abi.decode(payload, (WithdrawToParams));

        // 1. Pull liquidity — principal + accrued fees become positive deltas.
        for (uint256 i = 0; i < p.pulls.length; ++i) {
            _pullLiquidity(p.pulls[i].salt, p.pulls[i].liquidityToPull);
        }

        // 2. Convert freed legs into the requested currency (exactOut preferred).
        for (uint256 i = 0; i < p.swaps.length; ++i) {
            WithdrawSwap memory w = p.swaps[i];
            _swap(pools[_indexOf(w.poolId)].key, w.zeroForOne, w.amountSpecified, w.sqrtPriceLimitX96);
        }

        // 3. Guard: we must hold at least `amount` of the requested currency as a credit.
        int256 got = POOL_MANAGER.currencyDelta(address(this), p.requestedCurrency);
        if (got < int256(p.amount)) revert AmountNotDelivered(got > 0 ? uint256(got) : 0, p.amount);

        // 4. Deliver straight from PoolManager to recipient — bypasses our balance.
        _take(p.requestedCurrency, p.recipient, p.amount);

        // 5. Net residuals back to the manager (settle owed, take leftovers to self).
        _settleManaged();

        emit WithdrawnTo(p.recipient, p.requestedCurrency, p.amount);
        return "";
    }

    /// @dev Pull `liq` from the position keyed `salt` (at its stored range), skim the protocol fee off
    /// the accrued-fee component (principal untouched), and decrement/remove the registry entry. The
    /// pool key + range come from the stored position, so this is identical for both products.
    function _pullLiquidity(bytes32 salt, uint128 liq) internal {
        if (liq == 0) return;
        StoredPosition memory pos = _positions[salt];
        PoolKey memory key = pools[_indexOf(pos.poolId)].key;
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: -int256(uint256(liq)), salt: salt
            }),
            ""
        );
        _skimFees(key, fees);
        _positions[salt].liquidity -= liq;
        if (_positions[salt].liquidity == 0) {
            _removeSalt(salt);
            delete _positions[salt];
        }
    }

    // ────────── Position views + poke ──────────

    /// @inheritdoc V4PositionManager
    /// @dev Reconstructs the full `PoolKey` from the configured set (`poolId → pools[_indexOf]`); an
    /// absent position (`liquidity == 0`) returns the empty struct without reconstruction.
    function positionOf(bytes32 salt) external view override returns (Position memory pos) {
        StoredPosition memory s = _positions[salt];
        if (s.liquidity == 0) return pos;
        pos = Position({
            key: pools[_indexOf(s.poolId)].key,
            tickLower: s.tickLower,
            tickUpper: s.tickUpper,
            liquidity: s.liquidity,
            openedAt: s.openedAt
        });
    }

    /// @dev Harvest fees only (liquidityDelta == 0) for a position; principal unchanged. Reconstructs
    /// the pool key from config and routes `Op.POKE` to the product's own poke handler.
    /// @param salt The position key.
    function _pokeFromConfig(bytes32 salt) internal {
        StoredPosition memory s = _positions[salt];
        if (s.liquidity == 0) revert UnknownPosition(salt);
        PoolKey memory key = pools[_indexOf(s.poolId)].key;
        POOL_MANAGER.unlock(
            abi.encode(
                uint8(Op.POKE),
                abi.encode(
                    RemoveParams({
                        key: key, tickLower: s.tickLower, tickUpper: s.tickUpper, deltaLiquidity: 0, salt: salt
                    })
                )
            )
        );
    }

    // ────────── Owner config / inherited entry points ──────────

    /// @notice Owner escape hatch: execute a batch of arbitrary calls from the manager (e.g.
    /// rescue tokens, claim airdrops, approve a spender). A single call is just a 1-element
    /// batch. Empty `datas[i]` ⇒ native send. Owner-only — operators cannot move capital out.
    /// @param targets Addresses to call, one per batch element.
    /// @param values Native wei to forward per call (same length as `targets`).
    /// @param datas Calldata per call; an empty `datas[i]` ⇒ plain native transfer to `targets[i]`.
    /// @return results The raw bytes returned by each call, in order.
    function executeEncodedTxBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata datas)
        external
        onlyOwnerNFT
        returns (bytes[] memory results)
    {
        if (targets.length != values.length || targets.length != datas.length) {
            revert ArrayLengthMismatch();
        }
        results = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length; ++i) {
            if (datas[i].length == 0) {
                Address.sendValue(payable(targets[i]), values[i]);
            } else {
                results[i] = Address.functionCallWithValue(targets[i], datas[i], values[i]);
            }
        }
    }

    // ────────── Internal helpers ──────────

    /// @notice Number of configured pools.
    /// @return The length of `pools`.
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    /// @notice Number of distinct managed stables (union of all pool currencies).
    /// @return The length of `managedStables`.
    function managedStablesCount() external view returns (uint256) {
        return managedStables.length;
    }

    /// @dev Resolve a configured pool's array index from its poolId; reverts if not configured.
    function _indexOf(PoolId id) internal view returns (uint256) {
        uint256 idx = _poolIndexPlusOne[id];
        if (idx == 0) revert UnknownPool(id);
        return idx - 1;
    }

    /// @dev Net every managed currency: settle negatives from the manager balance, take positives
    /// (dust/residuals) to the manager. Iterates the deduped `managedStables` union.
    function _settleManaged() internal {
        uint256 n = managedStables.length;
        for (uint256 i = 0; i < n; ++i) {
            _settleCurrency(managedStables[i]);
        }
    }

    function _settleCurrency(Currency c) internal {
        int256 d = POOL_MANAGER.currencyDelta(address(this), c);
        if (d < 0) {
            _settle(c, uint256(-d));
        } else if (d > 0) {
            _take(c, address(this), uint256(d));
        }
    }

    /// @dev Positive part of a signed delta.
    function _pos(int128 x) internal pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }

    /// @dev Skim the protocol fee (`PROTOCOL_FEE_BPS` of the just-realized accrued fees) of both
    /// pool currencies straight to the treasury via the v4-native `take`, inside the active unlock.
    function _skimFees(PoolKey memory key, BalanceDelta feesAccrued) internal {
        _skimFee(key.currency0, feesAccrued.amount0());
        _skimFee(key.currency1, feesAccrued.amount1());
    }

    /// @dev Skim via ERC-6909 claims (not an ERC-20 transfer): a token blocklist/pause on the
    /// treasury then can't revert the unlock and lock LP principal. Treasury redeems the claims later.
    function _skimFee(Currency c, int128 fee) internal {
        // Round the protocol cut UP (favor the protocol; no sub-threshold zero-skim leak). Inline
        // ceil is safe: _pos(fee) ≤ uint128 max, so *BPS + 9_999 cannot overflow uint256.
        uint256 cut = (_pos(fee) * PROTOCOL_FEE_BPS + 9_999) / 10_000;
        if (cut == 0) return;
        _takeClaim(c, PROTOCOL_TREASURY, cut);
        emit ProtocolFeeTaken(c, cut);
    }
}
