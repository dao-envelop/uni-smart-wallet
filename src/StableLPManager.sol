// SPDX-License-Identifier: MIT
// Envelop V2, Uniswap Smart Wallet
// Powered by OpenZeppelin Contracts

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SingletonNFTOwned} from "./abstract/SingletonNFTOwned.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {PositionMath} from "./lib/PositionMath.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";

/// @title StableLPManager
/// @notice Clone-deployed, NFT-owned manager for stable-pair liquidity. The owner deposits
/// a single quote stable (e.g. USDT) and the manager auto-splits it across 3 fixed pools
/// (e.g. USDC/USDT, DAI/USDT, USDe/USDT) by weight, swapping-then-LPing inside one unlock
/// (`allocate`). Its headline feature is `withdrawTo`: deliver any managed stable to an
/// arbitrary recipient via the v4-native `take`, so the requested stable never lands on the
/// manager's or owner's ERC-20 balance.
/// @dev Reuses {SingletonNFTOwned} (auth) and {V4PositionManager} (V4 mechanics). It is
/// ERC20-only custody (accepts native via `receive`, no NFT/ERC1155 holders) and exposes a
/// single batch escape hatch (`executeEncodedTxBatch`) instead of inheriting Envelop's
/// SmartWallet — this keeps the clone implementation under the EIP-170 size limit. Deployed
/// as an EIP-1167 clone; config is injected via one-shot `initialize`, name/symbol are constants.
contract StableLPManager is SingletonNFTOwned, V4PositionManager {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant ORACLE_TYPE = 2002;
    uint16 internal constant TOTAL_BPS = 10_000;

    // Op codes extending the base 0–3 set (see V4PositionManager).
    uint8 internal constant OP_ALLOCATE = 4;
    uint8 internal constant OP_WITHDRAW_TO = 5;
    uint8 internal constant OP_REINVEST = 6;

    // ────────── Config structs ──────────

    struct PoolConfig {
        PoolKey key; // one of the 3 stable pools
        Currency quoteSide; // which side of the pair is the QUOTE stable
        int24 tickLower;
        int24 tickUpper;
        uint16 weightBps; // split weight; Σ across the 3 pools == 10_000
        bytes32 baseSalt; // deterministic salt seed for this pool's position
    }

    struct InitParams {
        address poolManager;
        address owner; // receives the singleton NFT
        PoolConfig[3] pools;
        Currency quote; // the deposited quote stable
    }

    // ────────── allocate structs ──────────

    struct AllocLeg {
        uint8 poolIndex; // 0..2
        uint256 quoteIn; // QUOTE assigned to this pool (Σ == totalQuote)
        uint256 swapQuoteToPair; // QUOTE to swap into the pair token (exactIn)
        uint160 swapPriceLimit; // sqrtPriceLimitX96 — slippage guard on the swap
        uint128 minLiquidity; // floor on minted L (slippage on the add)
        uint128 amount0Max; // settle caps
        uint128 amount1Max;
    }

    struct AllocateParams {
        uint256 totalQuote;
        AllocLeg[] legs;
    }

    // ────────── withdrawTo structs ──────────

    struct WithdrawStep {
        uint8 poolIndex;
        uint128 liquidityToPull; // modifyLiquidity(-L)
    }

    struct WithdrawSwap {
        uint8 poolIndex;
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

    IPoolManager private _pm;
    Currency public QUOTE;
    PoolConfig[3] public pools;
    mapping(Currency => bool) public isManagedStable;
    bool private _initialized;

    /// @notice External on-chain metadata renderer for `tokenURI`. Zero ⇒ `tokenURI` returns "".
    address public positionDescriptor;

    // ────────── Events ──────────

    // Envelop oracle compatibility (same as UniSmartWallet).
    event EnvelopV2OracleType(uint256 indexed oracleType, string contractName);
    event EnvelopWrappedV2(address indexed creator, uint256 indexed wnftTokenId, bytes32 indexed rules, bytes data);

    event Initialized(address indexed owner, address poolManager);
    event Allocated(uint256 totalQuote, uint128 l0, uint128 l1, uint128 l2);
    event WithdrawnTo(address indexed recipient, Currency indexed stable, uint256 amount);
    event Reinvested(bytes32 indexed salt, uint128 addedLiquidity);

    // ────────── Errors ──────────

    error AlreadyInitialized();
    error WeightsNotFull(uint16 sum);
    error UnknownPool(uint8 index);
    error UnmanagedStable(Currency c);
    error AmountNotDelivered(uint256 got, uint256 want);
    error SwapSlippage(uint8 poolIndex);
    error MinLiquidityNotMet(uint128 got, uint128 min);
    error RecipientZero();
    error QuoteSplitMismatch(uint256 sumQuoteIn, uint256 totalQuote);
    error ZeroAmount();
    error ArrayLengthMismatch();

    /// @dev Locks the implementation instance. Clones get fresh storage (`_initialized == false`)
    /// and never run this constructor.
    constructor() ERC721("", "") {
        _initialized = true;
    }

    /// @notice One-shot initializer, called by the factory on the freshly-cloned proxy.
    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        _pm = IPoolManager(p.poolManager);
        QUOTE = p.quote;
        isManagedStable[p.quote] = true;

        uint16 sum;
        for (uint8 i = 0; i < 3; ++i) {
            PoolConfig calldata c = p.pools[i];
            // Hookless-only: a pool with a non-zero hook can break LP economics, so reject config outright.
            if (address(c.key.hooks) != address(0)) revert HookNotAllowed(address(c.key.hooks));
            PositionMath.requireValidTickRange(c.tickLower, c.tickUpper, c.key.tickSpacing);
            pools[i] = c;
            isManagedStable[_pairSide(c.key.currency0, c.key.currency1)] = true;
            sum += c.weightBps;
        }
        if (sum != TOTAL_BPS) revert WeightsNotFull(sum);

        _mintSingleton(p.owner);

        emit IERC4906.MetadataUpdate(TOKEN_ID);
        emit EnvelopV2OracleType(ORACLE_TYPE, "StableLPManager");
        emit EnvelopWrappedV2(p.owner, TOKEN_ID, 0x0000, "");
        emit Initialized(p.owner, p.poolManager);
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return _pm;
    }

    // Clones don't run the ERC721 constructor, so expose name/symbol as constants.
    function name() public pure override returns (string memory) {
        return "Envelop StableLP";
    }

    function symbol() public pure override returns (string memory) {
        return "eStableLP";
    }

    /// @notice Set the external `tokenURI` renderer. Owner-only.
    function setPositionDescriptor(address descriptor) external onlyOwnerNFT {
        positionDescriptor = descriptor;
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice On-chain metadata for the singleton ownership token. Delegates to the configured
    /// {IWalletDescriptor}; returns "" if none is set (never reverts).
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        address descriptor = positionDescriptor;
        if (descriptor == address(0)) return "";
        return IWalletDescriptor(descriptor).tokenURI(address(this), id);
    }

    /// @dev Accept native transfers (e.g. gas refunds / dust). No NFT/ERC1155 custody.
    receive() external payable {}

    // ────────── Unlock dispatch ──────────

    /// @notice Fully overrides the base dispatcher to route ONLY the ops this product uses.
    /// Omitting OPEN/CLOSE makes the base's open/close handlers unreachable, so the compiler
    /// strips them — a deliberate bytecode-size reduction (keeps the clone under EIP-170).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(_poolManager())) revert NotPoolManager();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == uint8(Op.POKE)) return _handlePoke(payload); // claimFees
        if (op == OP_ALLOCATE) return _handleAllocate(payload);
        if (op == OP_WITHDRAW_TO) return _handleWithdrawTo(payload);
        if (op == OP_REINVEST) return _handleReinvest(payload);
        revert UnknownOp(op);
    }

    // ────────── allocate ──────────

    /// @notice Deposit `totalQuote` of QUOTE (already transferred in) and auto-split it across
    /// the configured pools per `legs` (swap-then-LP in one unlock).
    function allocate(AllocateParams calldata p) external onlyAuthorized nonReentrant {
        if (p.totalQuote == 0) revert ZeroAmount();
        uint256 sumQuote;
        for (uint256 i = 0; i < p.legs.length; ++i) {
            if (p.legs[i].poolIndex >= 3) revert UnknownPool(p.legs[i].poolIndex);
            sumQuote += p.legs[i].quoteIn;
        }
        if (sumQuote != p.totalQuote) revert QuoteSplitMismatch(sumQuote, p.totalQuote);
        _pm.unlock(abi.encode(OP_ALLOCATE, abi.encode(p)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleAllocate(bytes memory payload) internal returns (bytes memory) {
        AllocateParams memory p = abi.decode(payload, (AllocateParams));
        uint128[3] memory minted;
        for (uint256 i = 0; i < p.legs.length; ++i) {
            minted[p.legs[i].poolIndex] += _allocateLeg(p.legs[i]);
        }
        _settleManaged();
        emit Allocated(p.totalQuote, minted[0], minted[1], minted[2]);
        return "";
    }

    /// @dev Per-leg: swap QUOTE→pair (exactIn), size liquidity at the post-swap price, add it,
    /// enforce the slippage caps, and record/merge the position. Settlement is deferred to the
    /// final `_settleManaged()` net pass.
    function _allocateLeg(AllocLeg memory leg) internal returns (uint128 L) {
        PoolConfig memory P = pools[leg.poolIndex];
        bool quoteIsZero = _isQuoteCurrency0(P.key);

        uint256 pairForLp;
        if (leg.swapQuoteToPair > 0) {
            BalanceDelta sd = _swap(P.key, quoteIsZero, -int256(leg.swapQuoteToPair), leg.swapPriceLimit);
            int128 quoteDelta = quoteIsZero ? sd.amount0() : sd.amount1();
            // exactIn: a partial fill (price limit hit) leaves |quoteDelta| < requested input.
            if (uint256(uint128(-quoteDelta)) < leg.swapQuoteToPair) revert SwapSlippage(leg.poolIndex);
            int128 pairDelta = quoteIsZero ? sd.amount1() : sd.amount0();
            pairForLp = pairDelta > 0 ? uint256(uint128(pairDelta)) : 0;
        }

        uint256 quoteForLp = leg.quoteIn - leg.swapQuoteToPair;
        (uint256 amount0, uint256 amount1) = quoteIsZero ? (quoteForLp, pairForLp) : (pairForLp, quoteForLp);
        L = _addLiquidity(leg.poolIndex, amount0, amount1, leg.minLiquidity, leg.amount0Max, leg.amount1Max);
    }

    /// @dev Shared by allocate and reinvest: size liquidity at the current price, add it,
    /// enforce slippage caps, and record/merge the position. Settlement is the caller's job.
    function _addLiquidity(
        uint8 poolIndex,
        uint256 amount0,
        uint256 amount1,
        uint128 minLiq,
        uint128 max0,
        uint128 max1
    ) internal returns (uint128 L) {
        PoolConfig memory P = pools[poolIndex];
        bytes32 salt = _saltFor(poolIndex);
        (uint160 sqrtP,,,) = _pm.getSlot0(P.key.toId());

        L = PositionMath.liquidityFromAmounts(sqrtP, P.tickLower, P.tickUpper, amount0, amount1);
        if (L < minLiq) revert MinLiquidityNotMet(L, minLiq);

        (BalanceDelta ad,) = _pm.modifyLiquidity(
            P.key,
            ModifyLiquidityParams({
                tickLower: P.tickLower, tickUpper: P.tickUpper, liquidityDelta: int256(uint256(L)), salt: salt
            }),
            ""
        );
        _enforceCaps(ad, max0, max1);

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

    /// @notice Deliver `amount` of `requestedStable` to `recipient` without the stable ever
    /// touching the manager's or owner's balance. Owner-only — this is the drain primitive.
    function withdrawTo(WithdrawToParams calldata p) external onlyOwnerNFT nonReentrant {
        if (p.recipient == address(0)) revert RecipientZero();
        if (!isManagedStable[p.requestedStable]) revert UnmanagedStable(p.requestedStable);
        if (p.amount == 0) revert ZeroAmount();
        for (uint256 i = 0; i < p.pulls.length; ++i) {
            WithdrawStep calldata s = p.pulls[i];
            if (s.poolIndex >= 3) revert UnknownPool(s.poolIndex);
            uint128 have = positions[_saltFor(s.poolIndex)].liquidity;
            if (s.liquidityToPull > have) revert DeltaExceedsLiquidity(s.liquidityToPull, have);
        }
        _pm.unlock(abi.encode(OP_WITHDRAW_TO, abi.encode(p)));
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
            _swap(pools[w.poolIndex].key, w.zeroForOne, w.amountSpecified, w.sqrtPriceLimitX96);
        }

        // 3. Guard: we must hold at least `amount` of the requested stable as a credit.
        int256 got = _pm.currencyDelta(address(this), p.requestedStable);
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
        bytes32 salt = _saltFor(s.poolIndex);
        PoolConfig memory P = pools[s.poolIndex];
        _pm.modifyLiquidity(
            P.key,
            ModifyLiquidityParams({
                tickLower: P.tickLower,
                tickUpper: P.tickUpper,
                liquidityDelta: -int256(uint256(s.liquidityToPull)),
                salt: salt
            }),
            ""
        );
        positions[salt].liquidity -= s.liquidityToPull;
        if (positions[salt].liquidity == 0) {
            _removeSalt(salt);
            delete positions[salt];
        }
    }

    // ────────── reinvest / claimFees ──────────

    /// @notice Collect accrued fees on `salt` to the manager (no principal change).
    function claimFees(bytes32 salt) external onlyAuthorized nonReentrant {
        _pokePosition(salt);
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    /// @notice Compound realized fees of one pool back into its position.
    function reinvest(uint8 poolIndex, AllocLeg calldata leg) external onlyAuthorized nonReentrant {
        if (poolIndex >= 3) revert UnknownPool(poolIndex);
        _pm.unlock(abi.encode(OP_REINVEST, abi.encode(poolIndex, leg)));
        emit IERC4906.MetadataUpdate(TOKEN_ID);
    }

    function _handleReinvest(bytes memory payload) internal returns (bytes memory) {
        (uint8 poolIndex, AllocLeg memory leg) = abi.decode(payload, (uint8, AllocLeg));
        PoolConfig memory P = pools[poolIndex];
        bytes32 salt = _saltFor(poolIndex);

        // Realize fees as a positive caller delta. We deliberately ignore the second return
        // (feesAccrued): a single-LP pool lets an actor donate-to-self to inflate it.
        _pm.modifyLiquidity(
            P.key,
            ModifyLiquidityParams({tickLower: P.tickLower, tickUpper: P.tickUpper, liquidityDelta: 0, salt: salt}),
            ""
        );

        if (leg.swapQuoteToPair > 0) {
            _swap(P.key, _isQuoteCurrency0(P.key), -int256(leg.swapQuoteToPair), leg.swapPriceLimit);
        }

        // Size the add from the realized (positive) deltas of the two pool currencies.
        int256 d0 = _pm.currencyDelta(address(this), P.key.currency0);
        int256 d1 = _pm.currencyDelta(address(this), P.key.currency1);
        uint128 L = _addLiquidity(
            poolIndex,
            d0 > 0 ? uint256(d0) : 0,
            d1 > 0 ? uint256(d1) : 0,
            leg.minLiquidity,
            leg.amount0Max,
            leg.amount1Max
        );

        _settleCurrency(P.key.currency0);
        _settleCurrency(P.key.currency1);
        emit Reinvested(salt, L);
        return "";
    }

    // ────────── Owner config / inherited entry points ──────────

    /// @notice Owner escape hatch: execute a batch of arbitrary calls from the manager (e.g.
    /// rescue tokens, claim airdrops, approve a spender). A single call is just a 1-element
    /// batch. Empty `data[i]` ⇒ native send. Owner-only — operators cannot move capital out.
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

    function _saltFor(uint8 i) internal view returns (bytes32) {
        return keccak256(abi.encode(pools[i].baseSalt, i));
    }

    function _isQuoteCurrency0(PoolKey memory key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == Currency.unwrap(QUOTE);
    }

    /// @dev The non-quote (pair) side of a pool — what `withdrawTo` can deliver besides QUOTE.
    /// Takes the two currencies (not the whole PoolKey) to avoid struct memory copies.
    function _pairSide(Currency c0, Currency c1) internal view returns (Currency) {
        return Currency.unwrap(c0) == Currency.unwrap(QUOTE) ? c1 : c0;
    }

    function _enforceCaps(BalanceDelta ad, uint128 max0, uint128 max1) internal pure {
        int128 a0 = ad.amount0();
        int128 a1 = ad.amount1();
        uint256 owed0 = a0 < 0 ? uint256(uint128(-a0)) : 0;
        uint256 owed1 = a1 < 0 ? uint256(uint128(-a1)) : 0;
        if (owed0 > max0) revert ExceedsAmount0Max(owed0, max0);
        if (owed1 > max1) revert ExceedsAmount1Max(owed1, max1);
    }

    /// @dev Net every managed currency (QUOTE + 3 pair sides): settle negatives from the
    /// manager balance, take positives (dust/residuals) to the manager. Duplicate currencies
    /// are no-ops on the second pass (the delta is already zeroed).
    function _settleManaged() internal {
        _settleCurrency(QUOTE);
        _settleCurrency(_pairSide(pools[0].key.currency0, pools[0].key.currency1));
        _settleCurrency(_pairSide(pools[1].key.currency0, pools[1].key.currency1));
        _settleCurrency(_pairSide(pools[2].key.currency0, pools[2].key.currency1));
    }

    function _settleCurrency(Currency c) internal {
        int256 d = _pm.currencyDelta(address(this), c);
        if (d < 0) {
            _settle(c, uint256(-d));
        } else if (d > 0) {
            _take(c, address(this), uint256(d));
        }
    }
}
