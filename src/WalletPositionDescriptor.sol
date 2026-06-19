// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IWalletDescriptor} from "./interfaces/IWalletDescriptor.sol";
import {V4PositionManager} from "./abstract/V4PositionManager.sol";
import {PositionState} from "./lib/PositionState.sol";

/// @title WalletPositionDescriptor
/// @notice On-chain `tokenURI` renderer for the NFT-owned wallets. Emits a base64 `data:` JSON with
/// a per-position breakdown (principal + uncollected fees, valued live via {PositionState}) plus a
/// simple SVG summary card. Deployed once and shared; wallets delegate their `tokenURI` here so the
/// rendering bytecode stays out of the (EIP-170-bound) wallet. Adapts Uniswap's one-NFT-per-position
/// descriptor to a **singleton-portfolio** NFT (one token owning N salt-keyed positions).
contract WalletPositionDescriptor is IWalletDescriptor {
    using Strings for uint256;

    /// @inheritdoc IWalletDescriptor
    function tokenURI(address wallet, uint256 tokenId) external view returns (string memory) {
        V4PositionManager w = V4PositionManager(wallet);
        IPoolManager pm = w.POOL_MANAGER();
        uint256 n = w.openPositionCount();

        string memory json = string.concat(
            '{"name":"Envelop UniSmartWallet #',
            tokenId.toString(),
            '","description":"NFT-owned Uniswap V4 liquidity wallet. Holding this token controls the wallet and all of its positions.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(n))),
            '","attributes":[{"trait_type":"Open Positions","value":"',
            n.toString(),
            '"}],"positions":[',
            _positionsJson(w, pm, n),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
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

    function _svg(uint256 n) private pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180">',
            '<rect width="320" height="180" fill="#0b1021"/>',
            '<text x="20" y="48" fill="#7cf" font-family="monospace" font-size="18">Envelop UniSmartWallet</text>',
            '<text x="20" y="92" fill="#fff" font-family="monospace" font-size="14">Open positions: ',
            n.toString(),
            "</text>",
            '<text x="20" y="126" fill="#9aa" font-family="monospace" font-size="11">Uniswap V4 &#183; NFT owned</text>',
            "</svg>"
        );
    }
}
