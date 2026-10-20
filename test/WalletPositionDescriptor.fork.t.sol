// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WalletPositionDescriptor} from "../src/WalletPositionDescriptor.sol";
import {UniLens} from "../src/UniLens.sol";
import {DeployDescriptor} from "../script/DeployDescriptor.s.sol";
import {DescriptorConfig} from "../script/DescriptorConfig.sol";

interface IV3Slot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @notice task_055 live cross-check: a descriptor built from `chain_params.json` renders every live
/// manager with open positions, and each position's value equals the UniLens amounts × the configured
/// reference-pool prices, recomputed here independently (own resolution walk, different 512-bit split).
/// Env-gated, skipped without RPCs:
///
///   ARBITRUM_RPC=https://arb1.arbitrum.io/rpc UNICHAIN_RPC=https://mainnet.unichain.org \
///     forge test --match-path test/WalletPositionDescriptor.fork.t.sol -vv
///
/// `ARBITRUM_ARCHIVE_RPC` (an archive node) additionally replays the task_055 snapshot: AutoBot
/// `0x0dc6…be26` on 2026-09-29 00:00 UTC (L = 7 467 860 503 445 321 315 — the state task_055 decoded),
/// where the old card printed $259.66. The new card must land within 1 % of the task's positions +
/// fees figure ($89.69 + ~$0.27 net) — it is no longer off by 2.6x.
contract WalletPositionDescriptorForkTest is Test {
    using StateLibrary for IPoolManager;

    /// @dev Live Arbitrum managers with open positions (task_055 recount, 2026-09-30; + 0xeffe…, 10-15).
    address[] internal arbManagers = [
        0xCD302d069307312eF0A48eE2De6c41cd9754477b,
        0x3d536d021f75a96F46f2f07A5Ef6F59014D6dBDe,
        0xd07E17F017B9ffB48a258f209561087aAa3bBabD,
        0x115940ceEea6f02F90d9614a39c33257502D3841,
        0x0DC6d808eDF2a57c14dDAEF56eCDf3949CE5BE26,
        0xA3d8EdF658409B0cf43b5AB5D95d5F749489bb04,
        0xEfFEc674e0735913A39fdc60317bE9653CafE5Df
    ];
    address internal constant UNICHAIN_MANAGER = 0x7C77e35FAed086b948E68Cd2ab534991995c3B3B;
    address internal constant AUTOBOT = 0x0DC6d808eDF2a57c14dDAEF56eCDf3949CE5BE26;
    uint256 internal constant AUTOBOT_BLOCK = 509_864_043; // 2026-09-29 00:00:00 UTC

    WalletPositionDescriptor internal d;
    UniLens internal lens;
    address internal weth;
    address[] internal stables;
    WalletPositionDescriptor.RefInit[] internal refs;
    IPoolManager internal pm;

    function _fork(string memory env, string memory blockEnv, uint256 pinned) internal returns (bool) {
        string memory rpc = vm.envOr(env, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, string.concat(env, " unset"));
            return false;
        }
        uint256 b = pinned != 0 ? pinned : vm.envOr(blockEnv, uint256(0));
        if (b == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, b);

        DeployDescriptor deployer = new DeployDescriptor();
        DescriptorConfig.DescriptorParams memory params = deployer.readDescriptorParams(block.chainid);
        weth = params.weth;
        stables = params.stablecoins;
        for (uint256 i = 0; i < params.refs.length; ++i) {
            refs.push(params.refs[i]);
        }
        string memory json = vm.readFile("./script/chain_params.json");
        pm = IPoolManager(vm.parseJsonAddress(json, string.concat('.["', vm.toString(block.chainid), '"].poolManager')));
        d = deployer.deploy(pm, address(this), params);
        lens = new UniLens();
        return true;
    }

    // ────────── live ──────────

    function test_arbitrum_liveManagers_matchLensTimesPoolPrices() public {
        if (!_fork("ARBITRUM_RPC", "ARBITRUM_FORK_BLOCK", 0)) return;
        for (uint256 i = 0; i < arbManagers.length; ++i) {
            _checkManager(arbManagers[i]);
        }
    }

    function test_unichain_liveManager_matchesLensTimesPoolPrices() public {
        if (!_fork("UNICHAIN_RPC", "UNICHAIN_FORK_BLOCK", 0)) return;
        _checkManager(UNICHAIN_MANAGER);
    }

    /// @notice The task_055 incident, replayed: $259.66 on the old card, $99.25 real.
    function test_arbitrum_autobot_task055Snapshot() public {
        if (!_fork("ARBITRUM_ARCHIVE_RPC", "", AUTOBOT_BLOCK)) return;
        uint256 positions = _checkManager(AUTOBOT);

        // Idle: every managed currency (native via the balance) plus stray WETH, priced on the card's terms.
        uint256 idle;
        uint256 n = IManaged(AUTOBOT).managedStablesCount();
        for (uint256 i = 0; i < n; ++i) {
            address c = IManaged(AUTOBOT).managedStables(i);
            uint256 bal = c == address(0) ? AUTOBOT.balance : IERC20(c).balanceOf(AUTOBOT);
            (uint256 u, bool ok) = d.priceUsd(c, bal);
            assertTrue(ok || bal == 0, "idle priced");
            idle += u;
        }
        (uint256 w,) = d.priceUsd(weth, IERC20(weth).balanceOf(AUTOBOT));
        idle += w;
        uint256 total = positions + idle;
        console2.log("AutoBot 09-29: positions+fees (card), cents:", positions / 1e16);
        console2.log("AutoBot 09-29: + idle = total, cents:        ", total / 1e16);
        // task_055's table at this state: positions $89.69 + uncollected fees ~$0.30 gross (~$0.27 net of
        // the 10 % cut), at Chainlink prices. The card values the same amounts at pool prices.
        assertApproxEqRel(positions, 89.96e18, 0.01e18, "card within 1% of the task_055 positions figure");
        // Idle on-chain here is 6.866 ARB + 0.000535 ETH (~$2.8); the task's $99.25 counted 0.003035 ETH
        // of idle that this manager never held in this window, so the total is not asserted against it.
        assertApproxEqRel(total, positions + 2.82e18, 0.01e18, "idle as held on-chain");
    }

    // ────────── per manager ──────────

    /// @return sum The manager's positions value (principal + net fees), as the card renders it.
    function _checkManager(address m) internal view returns (uint256 sum) {
        string memory uri = d.tokenURI(m, 1); // never reverts on a live manager
        assertGt(bytes(uri).length, 100, "rendered");

        UniLens.PositionView[] memory pv = lens.positions(m);
        assertGt(pv.length, 0, "has positions");
        for (uint256 i = 0; i < pv.length; ++i) {
            WalletPositionDescriptor.Row memory r = d.positionValue(m, pv[i].salt);
            assertEq(r.flags & 2, 0, "every leg priced (reference or own pool)");
            assertEq(r.a0, pv[i].amount0, "amount0 == lens");
            assertEq(r.a1, pv[i].amount1, "amount1 == lens");
            assertEq(r.f0, pv[i].fees0 - (pv[i].fees0 * 1000 + 9999) / 10_000, "fees0 == lens, net");
            assertEq(r.f1, pv[i].fees1 - (pv[i].fees1 * 1000 + 9999) / 10_000, "fees1 == lens, net");

            uint256 expected = _leg(pv[i], true, r.a0 + r.f0) + _leg(pv[i], false, r.a1 + r.f1);
            uint256 got = r.principalUsd + r.feeUsd;
            uint256 tol = expected / 100 > 1e16 ? expected / 100 : 1e16; // 1 % or one cent
            assertApproxEqAbs(got, expected, tol, "position USD == lens amounts x pool prices");
            if (r.flags & 1 != 0) console2.log("  (priced by own pool)");
            sum += got;
        }
        console2.log(m, "positions value, cents:", sum / 1e16);
    }

    // ────────── independent pricing ──────────

    function _leg(UniLens.PositionView memory p, bool zero, uint256 amt) internal view returns (uint256) {
        if (amt == 0) return 0;
        address t = Currency.unwrap(zero ? p.key.currency0 : p.key.currency1);
        (uint256 usd, bool ok) = _usd(t, amt, 0);
        if (ok) return usd;
        address other = Currency.unwrap(zero ? p.key.currency1 : p.key.currency0);
        require(_isStable(other), "test: leg has no price source");
        return _stable(other, _conv(amt, p.sqrtPriceX96, zero));
    }

    function _usd(address t, uint256 amt, uint256 hop) internal view returns (uint256, bool) {
        if (_isStable(t)) return (_stable(t, amt), true);
        if (hop == 2) return (0, false);
        address ct = _canon(t);
        for (uint256 i = 0; i < refs.length; ++i) {
            WalletPositionDescriptor.RefInit memory r = refs[i];
            if (_canon(r.token) != ct) continue;
            address c0;
            address c1;
            uint160 sp;
            if (r.v3Pool != address(0)) {
                c0 = IV3Token(r.v3Pool).token0();
                c1 = IV3Token(r.v3Pool).token1();
                (sp,,,,,,) = IV3Slot0(r.v3Pool).slot0();
            } else {
                c0 = Currency.unwrap(r.v4Key.currency0);
                c1 = Currency.unwrap(r.v4Key.currency1);
                (sp,,,) = pm.getSlot0(r.v4Key.toId());
            }
            bool is0 = _canon(c0) == ct;
            return _usd(_canon(is0 ? c1 : c0), _conv(amt, sp, is0), hop + 1);
        }
        return (0, false);
    }

    function _isStable(address t) internal view returns (bool) {
        for (uint256 i = 0; i < stables.length; ++i) {
            if (stables[i] == t) return true;
        }
        return false;
    }

    function _stable(address s, uint256 amt) internal view returns (uint256) {
        return (amt * 1e18) / 10 ** IERC20Metadata(s).decimals();
    }

    function _canon(address t) internal view returns (address) {
        return t == weth ? address(0) : t;
    }

    /// @dev Different split from the descriptor (2^64 / 2^128 always).
    function _conv(uint256 amt, uint160 sp, bool tokenIs0) internal pure returns (uint256) {
        if (tokenIs0) return FullMath.mulDiv(FullMath.mulDiv(amt, sp, 1 << 64), sp, 1 << 128);
        return FullMath.mulDiv(FullMath.mulDiv(amt, 1 << 128, sp), 1 << 64, sp);
    }
}

interface IManaged {
    function managedStablesCount() external view returns (uint256);
    function managedStables(uint256) external view returns (address);
}

interface IV3Token {
    function token0() external view returns (address);
    function token1() external view returns (address);
}
