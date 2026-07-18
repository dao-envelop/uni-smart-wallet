// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
    function positions(address wallet) external view returns (PositionView[] memory views) {
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
