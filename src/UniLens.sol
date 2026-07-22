// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {StableLPManager} from "./StableLPManager.sol";
import {BaseLPManager} from "./BaseLPManager.sol";
import {PositionState} from "./lib/PositionState.sol";

/// @title UniLens
/// @notice Stateless read aggregator for frontends. One call returns the full open-position portfolio
/// of any NFT-owned {BaseLPManager} product (e.g. `StableLPManager`, a volatile-pair manager):
/// per-position principal + uncollected fees + the live pool price, plus manager config + idle
/// balances. Reuses {PositionState} (view-only, no `unlock`) — the same
/// valuation the on-chain `tokenURI` descriptor uses, but returned as structured data instead of
/// base64/SVG. Holds no state and is unaware of which concrete product it reads, so a single deployment
/// serves every wallet/manager on this chain.
contract UniLens {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /// @notice One open position, valued live at the current pool price.
    struct PositionView {
        bytes32 salt;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 openedAt;
        uint160 sqrtPriceX96; // live pool price (0 if the pool is uninitialized)
        uint256 amount0; // principal at the live price
        uint256 amount1;
        uint256 fees0; // uncollected fees
        uint256 fees1;
    }

    /// @notice `StableLPManager` configuration + idle balances (for the manage/deposit UI).
    struct ManagerView {
        address owner; // ownerOf(TOKEN_ID)
        uint16 protocolFeeBps;
        address treasury;
        Currency[] managedStables;
        uint256[] idleBalances; // the manager's own balance per managed stable (ERC-20 / native)
        BaseLPManager.PoolConfig[] pools; // configured pools
    }

    /// @notice A token (managed stable or caller-supplied extra) with its metadata + the manager's idle
    /// balance. `currency == address(0)` ⇒ native ETH (decimals 18, symbol `"ETH"`).
    struct StableInfo {
        Currency currency;
        uint8 decimals;
        string symbol;
        uint256 idle;
    }

    /// @notice A configured pool with its live price + total liquidity.
    struct PoolInfo {
        PoolKey key;
        uint160 sqrtPriceX96; // live pool price (0 if uninitialized)
        uint128 liquidity; // total pool liquidity
    }

    /// @notice Rich manager configuration — everything the manage/deposit UI needs in one read, so the
    /// frontend stops fanning out ~9 RPC round-trips per page. Product-agnostic ({BaseLPManager}).
    struct ManagerConfig {
        address owner; // ownerOf(TOKEN_ID)
        uint16 protocolFeeBps;
        address treasury;
        uint256 oracleType; // product tag: 3000 stable / 3001 volatile
        address positionDescriptor;
        address priceOracle;
        string name;
        StableInfo[] managed; // managed stables (index-aligned to managedStables) + metadata/idle
        StableInfo[] extra; // caller-supplied extraTokens with a NON-ZERO idle and not already managed
        PoolInfo[] pools; // configured pools + live slot0/liquidity
    }

    /// @notice {ManagerConfig} plus the full open-position portfolio — the "everything" getter.
    struct ManagerFull {
        ManagerConfig config;
        PositionView[] positions;
    }

    /// @notice Value a single open position of `wallet` (any {V4PositionManager}, e.g. `StableLPManager`).
    /// @param wallet The wallet/manager contract to read.
    /// @param salt The position key.
    /// @return The position valued live at the current pool price (principal + uncollected fees).
    function position(address wallet, bytes32 salt) external view returns (PositionView memory) {
        V4PositionManager w = V4PositionManager(wallet);
        return _view(w, w.POOL_MANAGER(), salt);
    }

    /// @notice The full open-position portfolio of `wallet`, each position valued live.
    /// @param wallet The wallet/manager contract to read.
    /// @return views One {PositionView} per open position.
    function positions(address wallet) public view returns (PositionView[] memory views) {
        V4PositionManager w = V4PositionManager(wallet);
        IPoolManager pm = w.POOL_MANAGER();
        uint256 n = w.openPositionCount();
        views = new PositionView[](n);
        for (uint256 i = 0; i < n; ++i) {
            views[i] = _view(w, pm, w.openSalts(i));
        }
    }

    /// @notice `StableLPManager`-specific config: owner, protocol fee/treasury, managed stables with the
    /// manager's idle balance of each, and the configured pools.
    /// @param manager The `StableLPManager` to read.
    /// @return info The manager configuration + per-stable idle balances.
    function managerInfo(address manager) external view returns (ManagerView memory info) {
        StableLPManager m = StableLPManager(payable(manager));
        info.owner = m.ownerOf(m.TOKEN_ID());
        info.protocolFeeBps = m.PROTOCOL_FEE_BPS();
        info.treasury = m.PROTOCOL_TREASURY();

        uint256 s = m.managedStablesCount();
        info.managedStables = new Currency[](s);
        info.idleBalances = new uint256[](s);
        for (uint256 i = 0; i < s; ++i) {
            Currency c = m.managedStables(i);
            info.managedStables[i] = c;
            info.idleBalances[i] = c.balanceOf(manager);
        }

        uint256 p = m.poolCount();
        info.pools = new BaseLPManager.PoolConfig[](p);
        for (uint256 i = 0; i < p; ++i) {
            PoolKey memory key = m.pools(i);
            info.pools[i] = BaseLPManager.PoolConfig({key: key});
        }
    }

    /// @notice Rich, single-call config getter: owner/fee/treasury, product tag, descriptor/oracle
    /// addresses, name, managed stables (with decimals/symbol/idle), any funded unmanaged extra tokens,
    /// and each configured pool with its live price + liquidity.
    /// @param manager The {BaseLPManager} product to read (`StableLPManager` / `VolatileLPManager`).
    /// @param extraTokens Candidate tokens (e.g. the chain's stablecoin list) to surface stray idle for;
    /// only those with a non-zero manager balance and not already managed are returned in `extra`.
    /// @return cfg The aggregated manager configuration.
    function managerConfig(address manager, address[] calldata extraTokens)
        public
        view
        returns (ManagerConfig memory cfg)
    {
        BaseLPManager m = BaseLPManager(payable(manager));
        cfg.owner = m.ownerOf(m.TOKEN_ID());
        cfg.protocolFeeBps = m.PROTOCOL_FEE_BPS();
        cfg.treasury = m.PROTOCOL_TREASURY();
        cfg.oracleType = m.ORACLE_TYPE();
        cfg.positionDescriptor = m.positionDescriptor();
        cfg.priceOracle = m.priceOracle();
        cfg.name = m.name();

        uint256 s = m.managedStablesCount();
        cfg.managed = new StableInfo[](s);
        for (uint256 i = 0; i < s; ++i) {
            cfg.managed[i] = _stableInfo(m.managedStables(i), manager);
        }

        // extra[]: caller-supplied tokens with a non-zero idle that are not already managed.
        StableInfo[] memory tmp = new StableInfo[](extraTokens.length);
        uint256 e;
        for (uint256 i = 0; i < extraTokens.length; ++i) {
            Currency c = Currency.wrap(extraTokens[i]);
            if (_isManaged(cfg.managed, c)) continue;
            if (c.balanceOf(manager) == 0) continue;
            tmp[e++] = _stableInfo(c, manager);
        }
        cfg.extra = new StableInfo[](e);
        for (uint256 i = 0; i < e; ++i) {
            cfg.extra[i] = tmp[i];
        }

        IPoolManager pm = m.POOL_MANAGER();
        uint256 p = m.poolCount();
        cfg.pools = new PoolInfo[](p);
        for (uint256 i = 0; i < p; ++i) {
            PoolKey memory key = m.pools(i);
            PoolId id = key.toId();
            (uint160 sqrtP,,,) = pm.getSlot0(id);
            cfg.pools[i] = PoolInfo({key: key, sqrtPriceX96: sqrtP, liquidity: pm.getLiquidity(id)});
        }
    }

    /// @notice The "everything" getter: {managerConfig} plus the full open-position portfolio.
    /// @param manager The {BaseLPManager} product to read.
    /// @param extraTokens Candidate unmanaged tokens to surface stray idle for (see {managerConfig}).
    /// @return full The manager config + one {PositionView} per open position.
    function managerFull(address manager, address[] calldata extraTokens)
        external
        view
        returns (ManagerFull memory full)
    {
        full.config = managerConfig(manager, extraTokens);
        full.positions = positions(manager);
    }

    /// @dev Read a token's metadata + the manager's idle balance. Native (`address(0)`) ⇒ decimals 18,
    /// symbol `"ETH"`; ERC-20 metadata is read defensively (see {_safeDecimals}/{_safeSymbol}).
    function _stableInfo(Currency c, address manager) private view returns (StableInfo memory si) {
        si.currency = c;
        si.idle = c.balanceOf(manager);
        if (c.isAddressZero()) {
            si.decimals = 18;
            si.symbol = "ETH";
        } else {
            address token = Currency.unwrap(c);
            si.decimals = _safeDecimals(token);
            si.symbol = _safeSymbol(token);
        }
    }

    /// @dev True if `c` is already among the managed stables.
    function _isManaged(StableInfo[] memory managed, Currency c) private pure returns (bool) {
        for (uint256 i = 0; i < managed.length; ++i) {
            if (Currency.unwrap(managed[i].currency) == Currency.unwrap(c)) return true;
        }
        return false;
    }

    /// @dev `decimals()` via low-level staticcall; falls back to 18 on revert / malformed return.
    function _safeDecimals(address token) private view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) return uint8(abi.decode(data, (uint256)));
        return 18;
    }

    /// @dev `symbol()` via low-level staticcall: try-decode as `string`, fall back to `bytes32`, then
    /// to the empty string on revert. (Some tokens revert or return a `bytes32` symbol — never bare-cast.)
    function _safeSymbol(address token) private view returns (string memory) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (!ok) return "";
        if (data.length == 32) return _bytes32ToString(bytes32(data));
        if (data.length >= 64) return abi.decode(data, (string));
        return "";
    }

    /// @dev Trim a right-padded `bytes32` symbol to its first NUL and return it as a string.
    function _bytes32ToString(bytes32 x) private pure returns (string memory) {
        uint256 len;
        while (len < 32 && x[len] != 0) ++len;
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            b[i] = x[i];
        }
        return string(b);
    }

    function _view(V4PositionManager w, IPoolManager pm, bytes32 salt) private view returns (PositionView memory v) {
        V4PositionManager.Position memory p = w.positionOf(salt);
        (uint160 sqrtP,,,) = pm.getSlot0(p.key.toId());
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = PositionState.value(pm, address(w), salt, p);
        v = PositionView({
            salt: salt,
            key: p.key,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: p.liquidity,
            openedAt: p.openedAt,
            sqrtPriceX96: sqrtP,
            amount0: a0,
            amount1: a1,
            fees0: f0,
            fees1: f1
        });
    }
}
