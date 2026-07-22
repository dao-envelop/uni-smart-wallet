// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {PositionState} from "./lib/PositionState.sol";
import {DescriptorLib} from "./lib/DescriptorLib.sol";

/// @dev Minimal view of the ERC-721 `name()` exposed by both products, so the descriptor can label
/// each token with its own product name (e.g. `StableLPManager` or a volatile-pair manager).
interface INftName {
    function name() external view returns (string memory);
}

/// @title WalletPositionDescriptor
/// @notice On-chain `tokenURI` renderer for the NFT-owned wallets. Emits a base64 `data:` JSON with
/// a per-position breakdown (principal + uncollected fees, valued live via {PositionState}) plus an
/// SVG summary card: Envelop logo watermark, the NFT `name()`, open-position count, total value,
/// stablecoin icons, and an approximate APR. Deployed once and shared; wallets delegate their
/// `tokenURI` here so the rendering bytecode stays out of the (EIP-170-bound) wallet/manager.
/// Adapts Uniswap's one-NFT-per-position descriptor to a **singleton-portfolio** NFT (one token
/// owning N salt-keyed positions).
contract WalletPositionDescriptor is IWalletDescriptor {
    using Strings for uint256;
    using StateLibrary for IPoolManager;

    /// @dev USD anchoring: a stablecoin leg is valued at $1; the paired (volatile) leg is converted to
    /// the stable leg at the live pool price (`sqrtPriceX96`). For pairs with NO stable leg there is no
    /// on-chain USD anchor, so we fall back to the naive `1 token == $1` model. The card is a pool-spot
    /// estimate, not a market oracle.
    uint256 private constant USD = 1e18;
    uint256 private constant Q96 = FixedPoint96.Q96;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @dev Per-chain stablecoin allowlist (set once at deploy) — currencies valued at $1 for the anchor.
    /// Stateless w.r.t. any manager, so one deployed descriptor still serves every clone on the chain.
    mapping(address => bool) private isStable;

    /// @param stablecoins The chain's stablecoin addresses (e.g. USDC/USDT/DAI) valued at $1.
    constructor(address[] memory stablecoins) {
        for (uint256 i = 0; i < stablecoins.length; ++i) {
            isStable[stablecoins[i]] = true;
        }
    }

    string private constant DESCRIPTION =
        "NFT-owned Uniswap V4 liquidity wallet. Holding this token controls the wallet and all of its positions.";

    /// @dev Portfolio aggregates, all USD figures 1e18-scaled.
    struct Stats {
        uint256 totalUsd; // principal + fees, all positions
        uint256 principalUsd; // principal only (APR denominator)
        uint256 annualFeeUsd; // Σ feeUsd_i · year / elapsed_i (APR numerator)
        Currency[] curs; // distinct currencies across positions (for icons)
    }

    /// @inheritdoc IWalletDescriptor
    function tokenURI(address wallet, uint256 tokenId) external view returns (string memory) {
        V4PositionManager w = V4PositionManager(wallet);
        uint256 n = w.openPositionCount();
        Stats memory s = _aggregate(w, w.POOL_MANAGER(), n);
        return string.concat("data:application/json;base64,", Base64.encode(bytes(_json(wallet, w, tokenId, n, s))));
    }

    /// @dev Assemble the raw metadata JSON. Split from {tokenURI} to keep the stack shallow.
    function _json(address wallet, V4PositionManager w, uint256 tokenId, uint256 n, Stats memory s)
        private
        view
        returns (string memory)
    {
        string memory nm = INftName(wallet).name();
        uint256 aprBps = s.principalUsd == 0 ? 0 : (s.annualFeeUsd * 10000) / s.principalUsd;

        string memory head =
            string.concat('{"name":"', nm, " #", tokenId.toString(), '","description":"', DESCRIPTION, '","image":"');
        string memory img = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(_svg(nm, n, s, aprBps))));
        string memory tail = string.concat(
            '","attributes":[',
            _attributes(n, s.totalUsd, aprBps),
            '],"positions":[',
            _positionsJson(w, w.POOL_MANAGER(), n),
            "]}"
        );
        return string.concat(head, img, tail);
    }

    // ────────── aggregation ──────────

    function _aggregate(V4PositionManager w, IPoolManager pm, uint256 n) private view returns (Stats memory s) {
        Currency[] memory tmp = new Currency[](2 * n);
        uint256 cn;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 salt = w.openSalts(i);
            V4PositionManager.Position memory p = w.positionOf(salt);
            (uint256 principalUsd, uint256 feeUsd) = _positionUsd(pm, address(w), salt, p);

            s.totalUsd += principalUsd + feeUsd;
            s.principalUsd += principalUsd;
            uint256 elapsed = block.timestamp > p.openedAt ? block.timestamp - p.openedAt : 0;
            if (elapsed > 0) s.annualFeeUsd += (feeUsd * SECONDS_PER_YEAR) / elapsed;

            cn = _pushDistinct(tmp, cn, p.key.currency0);
            cn = _pushDistinct(tmp, cn, p.key.currency1);
        }
        s.curs = new Currency[](cn);
        for (uint256 i = 0; i < cn; ++i) {
            s.curs[i] = tmp[i];
        }
    }

    /// @dev One position's principal/fee value in 1e18-scaled USD. When one leg is a stablecoin it is
    /// valued at $1 and the volatile leg is converted to it at the live pool price; a pair with no stable
    /// leg keeps the naive `1 token == $1` model (no on-chain USD anchor otherwise).
    function _positionUsd(IPoolManager pm, address w, bytes32 salt, V4PositionManager.Position memory p)
        private
        view
        returns (uint256 principalUsd, uint256 feeUsd)
    {
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = PositionState.value(pm, w, salt, p);

        if (isStable[Currency.unwrap(p.key.currency1)]) {
            // token1 = $1; convert token0 → token1 at the pool price.
            uint256 unit1 = 10 ** _decimals(p.key.currency1);
            (uint160 sp,,,) = pm.getSlot0(p.key.toId());
            principalUsd = (a1 * USD) / unit1 + (_q0to1(a0, sp) * USD) / unit1;
            feeUsd = (f1 * USD) / unit1 + (_q0to1(f0, sp) * USD) / unit1;
        } else if (isStable[Currency.unwrap(p.key.currency0)]) {
            // token0 = $1; convert token1 → token0 at the pool price.
            uint256 unit0 = 10 ** _decimals(p.key.currency0);
            (uint160 sp,,,) = pm.getSlot0(p.key.toId());
            principalUsd = (a0 * USD) / unit0 + (_q1to0(a1, sp) * USD) / unit0;
            feeUsd = (f0 * USD) / unit0 + (_q1to0(f1, sp) * USD) / unit0;
        } else {
            // No stable anchor → naive $1/token fallback.
            uint256 unit0 = 10 ** _decimals(p.key.currency0);
            uint256 unit1 = 10 ** _decimals(p.key.currency1);
            principalUsd = (a0 * USD) / unit0 + (a1 * USD) / unit1;
            feeUsd = (f0 * USD) / unit0 + (f1 * USD) / unit1;
        }
    }

    /// @dev token0 raw → token1 raw at price `sp`:  a0 · (sqrtP/2^96)^2. Two-step 512-bit mulDiv.
    function _q0to1(uint256 a0, uint160 sp) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a0, sp, Q96), sp, Q96);
    }

    /// @dev token1 raw → token0 raw at price `sp`:  a1 / (sqrtP/2^96)^2. Two-step 512-bit mulDiv.
    function _q1to0(uint256 a1, uint160 sp) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a1, Q96, sp), Q96, sp);
    }

    function _pushDistinct(Currency[] memory arr, uint256 count, Currency c) private pure returns (uint256) {
        for (uint256 i = 0; i < count; ++i) {
            if (Currency.unwrap(arr[i]) == Currency.unwrap(c)) return count;
        }
        arr[count] = c;
        return count + 1;
    }

    // ────────── token metadata (best-effort staticcall) ──────────

    /// @dev `decimals()` of a currency; native (`address(0)`) or non-conforming tokens ⇒ 18.
    function _decimals(Currency c) private view returns (uint8) {
        address t = Currency.unwrap(c);
        if (t == address(0)) return 18;
        (bool ok, bytes memory d) = t.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && d.length >= 32) return uint8(abi.decode(d, (uint256)));
        return 18;
    }

    /// @dev `symbol()` of a currency; native ⇒ "ETH", non-conforming ⇒ "?".
    function _symbol(Currency c) private view returns (string memory) {
        address t = Currency.unwrap(c);
        if (t == address(0)) return "ETH";
        (bool ok, bytes memory d) = t.staticcall(abi.encodeWithSignature("symbol()"));
        if (ok && d.length >= 64) return abi.decode(d, (string));
        return "?";
    }

    // ────────── image ──────────

    function _svg(string memory nm, uint256 n, Stats memory s, uint256 aprBps) private view returns (string memory) {
        string memory top = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320">',
            '<rect width="320" height="320" fill="#0b1021"/>',
            DescriptorLib.logo(),
            '<text x="20" y="40" fill="#4AFEBF" font-family="monospace" font-size="16">',
            nm,
            '</text><text x="20" y="92" fill="#9aa7bd" font-family="monospace" font-size="13">Open positions: ',
            n.toString(),
            "</text>"
        );
        string memory mid = string.concat(
            '<text x="20" y="128" fill="#9aa7bd" font-family="monospace" font-size="13">Total value</text>',
            '<text x="20" y="160" fill="#ffffff" font-family="monospace" font-size="26">$',
            DescriptorLib.formatUsd(s.totalUsd),
            '</text><text x="20" y="196" fill="#9aa7bd" font-family="monospace" font-size="13">~APR: ',
            DescriptorLib.formatPercentBps(aprBps),
            "</text>"
        );
        return string.concat(
            top,
            mid,
            _icons(s.curs),
            '<text x="20" y="306" fill="#5b6b86" font-family="monospace" font-size="11">Uniswap V4 &#183; NFT owned</text>',
            "</svg>"
        );
    }

    /// @dev A row of up to three stablecoin chips; a `+k` marker if more currencies exist.
    function _icons(Currency[] memory curs) private view returns (string memory out) {
        uint256 show = curs.length > 3 ? 3 : curs.length;
        for (uint256 i = 0; i < show; ++i) {
            out = string.concat(out, DescriptorLib.tokenIcon(_symbol(curs[i]), 20 + i * 92, 236));
        }
        if (curs.length > 3) {
            out = string.concat(
                out,
                '<text x="296" y="249" fill="#9aa7bd" font-family="monospace" font-size="12">+',
                (curs.length - 3).toString(),
                "</text>"
            );
        }
    }

    // ────────── JSON ──────────

    function _attributes(uint256 n, uint256 totalUsd, uint256 aprBps) private pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Open Positions","value":"',
            n.toString(),
            '"},{"trait_type":"Total Value (USD)","value":"',
            DescriptorLib.formatUsd(totalUsd),
            '"},{"trait_type":"Est. APR (bps)","value":"',
            aprBps.toString(),
            '"}'
        );
    }

    function _positionsJson(V4PositionManager w, IPoolManager pm, uint256 n) private view returns (string memory out) {
        for (uint256 i = 0; i < n; ++i) {
            string memory obj = _positionJson(w, pm, w.openSalts(i));
            out = i == 0 ? obj : string.concat(out, ",", obj);
        }
    }

    function _positionJson(V4PositionManager w, IPoolManager pm, bytes32 salt) private view returns (string memory) {
        V4PositionManager.Position memory p = w.positionOf(salt);
        (uint256 a0, uint256 a1, uint256 f0, uint256 f1) = PositionState.value(pm, address(w), salt, p);
        return string.concat(
            '{"salt":"',
            Strings.toHexString(uint256(salt), 32),
            '","currency0":"',
            Strings.toHexString(Currency.unwrap(p.key.currency0)),
            '","currency1":"',
            Strings.toHexString(Currency.unwrap(p.key.currency1)),
            '",',
            _ticksAndLiq(p),
            _amounts(a0, a1, f0, f1)
        );
    }

    function _ticksAndLiq(V4PositionManager.Position memory p) private pure returns (string memory) {
        return string.concat(
            '"tickLower":',
            Strings.toStringSigned(int256(p.tickLower)),
            ',"tickUpper":',
            Strings.toStringSigned(int256(p.tickUpper)),
            ',"liquidity":"',
            uint256(p.liquidity).toString(),
            '",'
        );
    }

    function _amounts(uint256 a0, uint256 a1, uint256 f0, uint256 f1) private pure returns (string memory) {
        return string.concat(
            '"amount0":"',
            a0.toString(),
            '","amount1":"',
            a1.toString(),
            '","fees0":"',
            f0.toString(),
            '","fees1":"',
            f1.toString(),
            '"}'
        );
    }
}
