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
import {PositionMath} from "./lib/PositionMath.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";

/// @title BaseLPManager
/// @notice Shared abstract base for the clone-deployed, NFT-owned LP managers. Holds a configurable
/// set of hookless pools; the owner deposits managed currencies and the operator drives liquidity
/// via `allocate` / `allocateFrom`, with `withdrawTo` (indirect drain via v4-native `take`),
/// `reinvest`, and `claimFees`. Products (e.g. `StableLPManager`, a volatile-pair manager) subclass
/// this and supply their identity (`ORACLE_TYPE` / `symbol` / product name / default NFT name) and
/// may override the per-leg add (`_allocateLeg` / `_addLiquidity`) to change range/slippage policy.
/// @dev Reuses {SingletonNFTOwned} (auth) and {V4PositionManager} (V4 mechanics). ERC20-only custody
/// (accepts native via `receive`, no NFT/ERC1155 holders) with a single batch escape hatch
/// (`executeEncodedTxBatch`) instead of Envelop's SmartWallet — keeps each clone under EIP-170.
/// Deployed as an EIP-1167 clone; config is injected via one-shot `initialize`.
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
    /// @dev Fallback NFT name (product-specific) used when `InitParams.name` is empty (`bytes32(0)`).
    function _defaultName() internal pure virtual returns (bytes32);

    // Op codes extending the base 0–3 set (see V4PositionManager).
    uint8 internal constant OP_ALLOCATE = 4;
    uint8 internal constant OP_WITHDRAW_TO = 5;
    uint8 internal constant OP_REINVEST = 6;

    // ────────── Config structs ──────────

    struct PoolConfig {
        PoolKey key; // a stable pool (arbitrary pair); its poolId is the position salt
        int24 tickLower;
        int24 tickUpper;
    }

    struct InitParams {
        address owner; // receives the singleton NFT
        bytes32 name; // NFT name, packed (≤31 chars, trailing zeros trimmed); "" ⇒ default name "Envelop LP Uniswap Manager"
        PoolConfig[] pools; // 1..MAX_POOLS arbitrary stable pools
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

    struct WithdrawStep {
        PoolId poolId;
        uint128 liquidityToPull; // modifyLiquidity(-L)
    }

    struct WithdrawSwap {
        PoolId poolId;
        bool zeroForOne;
        int256 amountSpecified; // convert a freed leg into requestedStable (exactOut preferred)
        uint160 sqrtPriceLimitX96; // per-swap slippage guard
    }

    struct WithdrawToParams {
        address recipient;
        Currency requestedStable;
        uint256 amount; // exact amount delivered to recipient
        WithdrawStep[] pulls;
        WithdrawSwap[] swaps;
        /// @dev Phase 1: residuals always return to the manager; reinvest-on-withdraw is not
        /// yet implemented (use `reinvest()`). Field retained for ABI/spec compatibility.
        bool reinvestRemainder;
    }

    // ────────── State ──────────

    /// @notice The configured pools (fixed at `initialize`); each entry's poolId is its position salt.
    PoolConfig[] public pools;
    /// @notice 1-based index of a pool in `pools` keyed by its poolId (0 ⇒ not configured).
    mapping(PoolId => uint256) internal _poolIndexPlusOne;
    /// @notice Whether a currency is a managed stable (a currency of some configured pool).
    mapping(Currency => bool) public isManagedStable;
    /// @notice Enumerable union of all currencies across `pools` (for net settlement).
    Currency[] public managedStables;
    bool private _initialized;
    bytes32 private _name; // per-clone NFT name, packed; set once in initialize

    /// @notice External on-chain metadata renderer for `tokenURI`. Zero ⇒ `tokenURI` returns "".
    address public positionDescriptor;

    /// @notice Protocol fee recipient. Immutable — set by the protocol at implementation deploy and
    /// shared by every clone; NOT owner-settable, so the fee can't be redirected away from the protocol.
    address public immutable PROTOCOL_TREASURY;

    // ────────── Events ──────────

    // Envelop oracle compatibility (same as UniSmartWallet).
    /// @notice Emitted once at initialize so existing Envelop V2 oracles can index this manager.
    /// @param oracleType The Envelop oracle type tag (`ORACLE_TYPE` = 2002).
    /// @param contractName The contract name (`"StableLPManager"`).
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
    /// initialized. Clones (the actual managers) are created by {StableLPFactory}, not this constructor.
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

    /// @notice One-shot initializer, called by the factory on the freshly-cloned proxy: registers the
    /// pools + managed stables, mints the singleton NFT to `p.owner`, and reverts if called twice.
    /// @param p Init parameters: owner, packed NFT name (empty ⇒ default), and 1..MAX_POOLS pools.
    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _name = p.name;

        uint256 n = p.pools.length;
        if (n == 0) revert NoPools();
        if (n > MAX_POOLS) revert TooManyPools(n);

        for (uint256 i = 0; i < n; ++i) {
            PoolConfig calldata c = p.pools[i];
            // Hookless-only: a pool with a non-zero hook can break LP economics, so reject config outright.
            if (address(c.key.hooks) != address(0)) revert HookNotAllowed(address(c.key.hooks));
            PositionMath.requireValidTickRange(c.tickLower, c.tickUpper, c.key.tickSpacing);
            PoolId id = c.key.toId();
            if (_poolIndexPlusOne[id] != 0) revert DuplicatePool(id); // poolId == position salt ⇒ must be unique
            pools.push(c);
            _poolIndexPlusOne[id] = pools.length; // 1-based
            _registerManaged(c.key.currency0);
            _registerManaged(c.key.currency1);
        }

        _mintSingleton(p.owner);

        emit IERC4906.MetadataUpdate(TOKEN_ID);
        emit EnvelopV2OracleType(ORACLE_TYPE(), _productName());
        emit EnvelopWrappedV2(p.owner, TOKEN_ID, 0x0000, "");
        emit Initialized(p.owner, address(POOL_MANAGER), n);
    }

    /// @dev Add a currency to the managed-stable set (dedup via the mapping).
    function _registerManaged(Currency c) internal {
        if (!isManagedStable[c]) {
            isManagedStable[c] = true;
            managedStables.push(c);
        }
    }

    /// @notice The per-clone NFT name. Decodes the packed `_name` set at `initialize`; an empty name
    /// falls back to the default `"Envelop LP Uniswap Manager"`.
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

    /// @notice PoolManager unlock callback. Fully overrides the base dispatcher to route ONLY the ops
    /// this product uses (POKE/ALLOCATE/WITHDRAW_TO/REINVEST). Omitting OPEN/CLOSE makes the base's
    /// open/close handlers unreachable, so the compiler strips them — a deliberate bytecode-size
    /// reduction (keeps the clone under EIP-170). Reverts unless called by the PoolManager.
    /// @param data ABI-encoded `(uint8 op, bytes payload)` produced by this manager before `unlock`.
    /// @return Empty bytes (settlement happens inside the handlers).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == uint8(Op.POKE)) return _handleClaim(payload); // claimFees (with protocol fee)
        if (op == OP_ALLOCATE) return _handleAllocate(payload);
        if (op == OP_WITHDRAW_TO) return _handleWithdrawTo(payload);
        if (op == OP_REINVEST) return _handleReinvest(payload);
        revert UnknownOp(op);
    }

    // ────────── allocate ──────────

    /// @notice Auto mode: deploy liquidity per `legs`, drawing from whatever managed stables sit on
    /// the manager's balance; residuals net back to the manager. Owner-or-operator (off-chain sizing).
    /// @param legs Per-pool actions (optional pre-swap + desired add amounts + slippage floor).
    function allocate(AllocLeg[] calldata legs) external onlyAuthorized nonReentrant {
        _validateLegs(legs);
        POOL_MANAGER.unlock(abi.encode(OP_ALLOCATE, abi.encode(legs)));
        emit Allocated(legs.length);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice Manual mode: deploy a specific just-deposited `stable` (>= `amount` must already sit
    /// on the manager). Guards that the operation draws down ONLY `stable` — no other managed stable
    /// balance may decrease — so deposit-and-allocate can't dip into pre-existing holdings.
    /// Owner-or-operator.
    /// @param stable The managed stable being deployed (the only balance allowed to decrease).
    /// @param amount Amount that must already sit on the manager (snapshot guard reference).
    /// @param legs Per-pool actions (optional pre-swap + desired add amounts + slippage floor).
    function allocateFrom(Currency stable, uint256 amount, AllocLeg[] calldata legs)
        external
        onlyAuthorized
        nonReentrant
    {
        if (!isManagedStable[stable]) revert UnmanagedStable(stable);
        if (amount == 0) revert ZeroAmount();
        uint256 have = stable.balanceOfSelf();
        if (have < amount) revert NotDeposited(stable, have, amount);
        _validateLegs(legs);

        uint256 n = managedStables.length;
        uint256[] memory pre = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            pre[i] = managedStables[i].balanceOfSelf();
        }

        POOL_MANAGER.unlock(abi.encode(OP_ALLOCATE, abi.encode(legs)));

        // Only `stable` may have decreased; every other managed stable must end >= its pre-balance.
        for (uint256 i = 0; i < n; ++i) {
            Currency c = managedStables[i];
            if (Currency.unwrap(c) == Currency.unwrap(stable)) continue;
            if (c.balanceOfSelf() < pre[i]) revert UnexpectedStableSpend(c);
        }

        emit Allocated(legs.length);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _validateLegs(AllocLeg[] calldata legs) internal view {
        if (legs.length == 0) revert NoLegs();
        for (uint256 i = 0; i < legs.length; ++i) {
            _indexOf(legs[i].poolId); // reverts UnknownPool if not configured
        }
    }

    function _handleAllocate(bytes memory payload) internal returns (bytes memory) {
        AllocLeg[] memory legs = abi.decode(payload, (AllocLeg[]));
        for (uint256 i = 0; i < legs.length; ++i) {
            _allocateLeg(legs[i]);
        }
        _settleManaged();
        return "";
    }

    /// @dev Per-leg: optional exactIn pre-swap to balance the sides, then add liquidity sized from
    /// the operator's desired amounts. Settlement is deferred to the final `_settleManaged()` pass.
    function _allocateLeg(AllocLeg memory leg) internal virtual returns (uint128 L) {
        PoolConfig memory P = pools[_indexOf(leg.poolId)];
        if (leg.swapAmountIn > 0) {
            BalanceDelta sd = _swap(P.key, leg.zeroForOne, -int256(leg.swapAmountIn), leg.swapPriceLimit);
            int128 inDelta = leg.zeroForOne ? sd.amount0() : sd.amount1();
            // exactIn: a partial fill (price limit hit) leaves |inDelta| < requested input.
            if (uint256(uint128(-inDelta)) < leg.swapAmountIn) revert SwapSlippage(leg.poolId);
        }
        L = _addLiquidity(leg.poolId, P, leg.amount0Desired, leg.amount1Desired, leg.minLiquidity);
    }

    /// @dev Shared by allocate and reinvest: size liquidity at the current price, add it, and
    /// record/merge the position (`salt == poolId`). Settlement is the caller's job. `P` is passed in
    /// (already resolved by the caller) to avoid a re-lookup. No per-side spend cap is needed: `L` is
    /// sized from `amount{0,1}` at the on-chain price, so the realized owed is `<= amount{0,1}`.
    function _addLiquidity(PoolId id, PoolConfig memory P, uint256 amount0, uint256 amount1, uint128 minLiq)
        internal
        virtual
        returns (uint128 L)
    {
        bytes32 salt = PoolId.unwrap(id);
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(id);
        if (sqrtP == 0) revert PoolUninitialized();

        L = PositionMath.liquidityFromAmounts(sqrtP, P.tickLower, P.tickUpper, amount0, amount1);
        if (L < minLiq) revert MinLiquidityNotMet(L, minLiq);

        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            P.key,
            ModifyLiquidityParams({
                tickLower: P.tickLower, tickUpper: P.tickUpper, liquidityDelta: int256(uint256(L)), salt: salt
            }),
            ""
        );
        _skimFees(P.key, fees); // protocol fee on any accrued fees realized by a top-up

        if (positions[salt].liquidity == 0) {
            positions[salt] = Position({
                key: P.key,
                tickLower: P.tickLower,
                tickUpper: P.tickUpper,
                liquidity: L,
                openedAt: uint64(block.timestamp)
            });
            _registerSalt(salt);
        } else {
            positions[salt].liquidity += L;
        }
    }

    // ────────── withdrawTo (indirect withdraw) ──────────

    /// @notice Deliver `p.amount` of `p.requestedStable` to `p.recipient` without the stable ever
    /// touching the manager's or owner's balance (v4-native `take`). Owner-only — the drain primitive.
    /// @param p Withdraw plan: recipient, requested stable + amount, liquidity pulls, and conversion
    /// swaps. `reinvestRemainder` is reserved (phase-1 no-op; residuals always return to the manager).
    function withdrawTo(WithdrawToParams calldata p) external onlyOwnerNFT nonReentrant {
        if (p.recipient == address(0)) revert RecipientZero();
        if (!isManagedStable[p.requestedStable]) revert UnmanagedStable(p.requestedStable);
        if (p.amount == 0) revert ZeroAmount();
        for (uint256 i = 0; i < p.pulls.length; ++i) {
            WithdrawStep calldata s = p.pulls[i];
            _indexOf(s.poolId); // reverts UnknownPool if not configured
            uint128 have = positions[PoolId.unwrap(s.poolId)].liquidity;
            if (s.liquidityToPull > have) revert DeltaExceedsLiquidity(s.liquidityToPull, have);
        }
        POOL_MANAGER.unlock(abi.encode(OP_WITHDRAW_TO, abi.encode(p)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleWithdrawTo(bytes memory payload) internal returns (bytes memory) {
        WithdrawToParams memory p = abi.decode(payload, (WithdrawToParams));

        // 1. Pull liquidity — principal + accrued fees become positive deltas.
        for (uint256 i = 0; i < p.pulls.length; ++i) {
            _pullLiquidity(p.pulls[i]);
        }

        // 2. Convert freed legs into the requested stable (exactOut preferred).
        for (uint256 i = 0; i < p.swaps.length; ++i) {
            WithdrawSwap memory w = p.swaps[i];
            _swap(pools[_indexOf(w.poolId)].key, w.zeroForOne, w.amountSpecified, w.sqrtPriceLimitX96);
        }

        // 3. Guard: we must hold at least `amount` of the requested stable as a credit.
        int256 got = POOL_MANAGER.currencyDelta(address(this), p.requestedStable);
        if (got < int256(p.amount)) revert AmountNotDelivered(got > 0 ? uint256(got) : 0, p.amount);

        // 4. Deliver straight from PoolManager to recipient — bypasses our balance.
        _take(p.requestedStable, p.recipient, p.amount);

        // 5. Net residuals back to the manager (settle owed, take leftovers to self).
        _settleManaged();

        emit WithdrawnTo(p.recipient, p.requestedStable, p.amount);
        return "";
    }

    function _pullLiquidity(WithdrawStep memory s) internal {
        if (s.liquidityToPull == 0) return;
        bytes32 salt = PoolId.unwrap(s.poolId);
        PoolConfig memory P = pools[_indexOf(s.poolId)];
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            P.key,
            ModifyLiquidityParams({
                tickLower: P.tickLower,
                tickUpper: P.tickUpper,
                liquidityDelta: -int256(uint256(s.liquidityToPull)),
                salt: salt
            }),
            ""
        );
        _skimFees(P.key, fees); // protocol fee on the accrued-fee component (principal untouched)
        positions[salt].liquidity -= s.liquidityToPull;
        if (positions[salt].liquidity == 0) {
            _removeSalt(salt);
            delete positions[salt];
        }
    }

    // ────────── reinvest / claimFees ──────────

    /// @notice Collect accrued fees on `salt` to the manager (no principal change). The protocol
    /// fee is skimmed first; the remainder lands on the manager. Owner-or-operator.
    /// @param salt The position key (`== poolId`).
    function claimFees(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokePosition(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @dev POKE handler (replaces the base one): realize fees, skim the protocol cut, net the
    /// remainder to the manager.
    function _handleClaim(bytes memory payload) internal returns (bytes memory) {
        RemoveParams memory r = abi.decode(payload, (RemoveParams));
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            r.key,
            ModifyLiquidityParams({tickLower: r.tickLower, tickUpper: r.tickUpper, liquidityDelta: 0, salt: r.salt}),
            ""
        );
        _skimFees(r.key, fees);
        _settleCurrency(r.key.currency0);
        _settleCurrency(r.key.currency1);
        emit FeesCollected(r.salt, _pos(fees.amount0()), _pos(fees.amount1()));
        return "";
    }

    /// @notice Compound realized fees of one pool back into its position. The pool is `leg.poolId`.
    /// Owner-or-operator.
    /// @param leg The pool action: which pool (`leg.poolId`), optional balancing pre-swap, and the
    /// `minLiquidity` floor. The add is sized from the realized fee deltas, not `amount{0,1}Desired`.
    function reinvest(AllocLeg calldata leg) external onlyAuthorized nonReentrant {
        _indexOf(leg.poolId); // reverts UnknownPool if not configured
        POOL_MANAGER.unlock(abi.encode(OP_REINVEST, abi.encode(leg)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleReinvest(bytes memory payload) internal returns (bytes memory) {
        AllocLeg memory leg = abi.decode(payload, (AllocLeg));
        PoolConfig memory P = pools[_indexOf(leg.poolId)];
        bytes32 salt = PoolId.unwrap(leg.poolId);

        // Realize fees as a positive caller delta, then skim the protocol cut before compounding.
        (, BalanceDelta fees) = POOL_MANAGER.modifyLiquidity(
            P.key,
            ModifyLiquidityParams({tickLower: P.tickLower, tickUpper: P.tickUpper, liquidityDelta: 0, salt: salt}),
            ""
        );
        _skimFees(P.key, fees);

        if (leg.swapAmountIn > 0) {
            _swap(P.key, leg.zeroForOne, -int256(leg.swapAmountIn), leg.swapPriceLimit);
        }

        // Size the add from the realized (positive) deltas of the two pool currencies.
        int256 d0 = POOL_MANAGER.currencyDelta(address(this), P.key.currency0);
        int256 d1 = POOL_MANAGER.currencyDelta(address(this), P.key.currency1);
        uint128 L = _addLiquidity(leg.poolId, P, d0 > 0 ? uint256(d0) : 0, d1 > 0 ? uint256(d1) : 0, leg.minLiquidity);

        _settleCurrency(P.key.currency0);
        _settleCurrency(P.key.currency1);
        emit Reinvested(salt, L);
        return "";
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
