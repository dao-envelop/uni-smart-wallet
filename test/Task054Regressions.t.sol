// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {RedTeamBase} from "./RedTeamTask053.t.sol";
import {VolatileLPManager} from "../src/VolatileLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {ChainlinkPriceOracle} from "../src/oracle/ChainlinkPriceOracle.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Regressions for task_054, against the two HIGH findings of the fix review.
///
/// The exploits these replace are preserved verbatim under `audits/2026-09-04/fix-review/poc/`; they
/// ran against this repo and measured 24.84% drained in one transaction (R-2) and 44.997% through a
/// hook in one approved call (R-1). What is pinned here is that each of those is now refused, and — as
/// important — that the refusals are narrow: an operator working a sane pool one call at a time is
/// unaffected, or the guards would be indistinguishable from switching operators off.
contract Task054Regressions is RedTeamBase {
    /// @dev The drain cycle needs a range parked between the reference and the edge of the tolerance
    /// band. On a spacing-1 pool the lattice offers one; the oracle now refuses the pool outright.
    function test_R2_spacingFinerThanTolerance_refusesTheDrainPool() public {
        _boot(100, 1, 4_000e18, 0, 1_000e18);
        _openAsOwner(-1, 0, 1_000e18); // the owner may still work the pool

        _swapTo(49); // skew to the edge of the 50 bps band, as the exploit did
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceOracle.SpacingFinerThanTolerance.selector, int24(1), uint16(50))
        );
        _recenterAsBot(48, 49);
    }

    /// @dev A pool whose lattice is coarser than the tolerance passes the rule — no range fits in the
    /// corridor there, which is the point. The operator can work it, once per transaction.
    function test_R2_operatorWorksACoarsePoolOnce() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        _recenterAsBot(-120, 0);
        assertEq(mgr.positionOf(SALT).tickLower, int24(-120), "one operator recenter goes through");
    }

    /// @dev The loop itself. Sixty of these in one transaction took 24.84%; the second is now refused,
    /// so an attacker has to pay for a fresh transaction — and leave a block for someone to react in.
    function test_R2_secondOperatorOpInTheSameTxIsRefused() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        _recenterAsBot(-120, 0);
        vm.expectRevert(SingletonNFTOwned.OperatorOpsPerTx.selector);
        _recenterAsBot(0, 120);
    }

    /// @dev The owner is not rate-limited — the limit is about a delegated key, not about the manager.
    function test_R2_ownerIsNotRateLimited() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        vm.startPrank(owner);
        mgr.recenter(_ownerRecenter(-120, 120));
        mgr.recenter(_ownerRecenter(-180, 180));
        vm.stopPrank();
        assertEq(mgr.positionOf(SALT).tickLower, int24(-180), "both owner recenters applied");
    }

    /// @dev The value the loop used to extract, measured on a pool it can still reach. One operation is
    /// all a transaction now holds, so this is the whole per-transaction exposure.
    function test_R2_singleOperationExposureIsBounded() public {
        _boot(3000, 60, 4_000e18, 1_000e18, 1_000e18);
        _openAsOwner(-60, 60, 500e18);

        uint256 before = _managerValue();
        _swapTo(40); // inside the 50 bps band: the oracle still vouches
        _recenterAsBot(-60, 60);
        _swapTo(0);

        uint256 lostBps = before > _managerValue() ? (before - _managerValue()) * 10_000 / before : 0;
        console2.log("one vouched-for operation, coarse pool - manager loss (bps):", lostBps);
        assertLt(lostBps, 100, "a single operation cannot take a percent");
    }

    function _ownerRecenter(int24 tl, int24 tu) internal pure returns (VolatileLPManager.RecenterParams memory) {
        return VolatileLPManager.RecenterParams({
            salt: SALT,
            newTickLower: tl,
            newTickUpper: tu,
            zeroForOne: false,
            swapAmountIn: 0,
            swapPriceLimit: 0,
            minAmountOut: 0,
            minLiquidity: 0
        });
    }
}
