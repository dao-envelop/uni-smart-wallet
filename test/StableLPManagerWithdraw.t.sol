// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableLPTestBase} from "./helpers/StableLPTestBase.sol";
import {StableLPManager} from "../src/StableLPManager.sol";
import {BaseLPManager} from "../src/BaseLPManager.sol";
import {SingletonNFTOwned} from "../src/abstract/SingletonNFTOwned.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract StableLPManagerWithdrawTest is StableLPTestBase {
    address internal recipient = address(0xFEED);

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        mgr.allocate(_allocateParams(FUND));
    }

    /// THE headline invariant: deliver USDC to a recipient, funded by pulling the DAI/USDT
    /// pool and exact-out swapping freed USDT → USDC. The requested stable must never land
    /// on the manager's or owner's balance.
    function test_withdrawTo_deliversToRecipient_managerBalanceUnchanged() public {
        uint256 amount = 10e18;
        uint256 mgrUSDCBefore = _bal(USDC, address(mgr));
        uint256 ownerUSDCBefore = _bal(USDC, owner);

        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        pulls[0] =
            BaseLPManager.WithdrawStep({salt: _saltFor(1), liquidityToPull: mgr.positionOf(_saltFor(1)).liquidity});

        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](1);
        swaps[0] = _exactOut(0, USDC, amount); // produce exactly `amount` USDC in the USDC/USDT pool

        vm.prank(owner);
        mgr.withdrawTo(
            BaseLPManager.WithdrawToParams({
                recipient: recipient, requestedCurrency: USDC, amount: amount, pulls: pulls, swaps: swaps
            })
        );

        assertEq(_bal(USDC, recipient), amount, "recipient received exactly amount");
        assertEq(_bal(USDC, address(mgr)), mgrUSDCBefore, "manager USDC balance unchanged");
        assertEq(_bal(USDC, owner), ownerUSDCBefore, "owner USDC balance unchanged");
        // The pulled pool's position is gone.
        assertEq(mgr.positionOf(_saltFor(1)).liquidity, 0, "DAI/USDT position closed");
    }

    function test_withdrawTo_unmanagedStable_reverts() public {
        Currency rogue = _mkToken();
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](0);
        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.UnmanagedStable.selector, rogue));
        mgr.withdrawTo(BaseLPManager.WithdrawToParams(recipient, rogue, 1e18, pulls, swaps));
    }

    function test_withdrawTo_recipientZero_reverts() public {
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](0);
        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](0);
        vm.prank(owner);
        vm.expectRevert(BaseLPManager.RecipientZero.selector);
        mgr.withdrawTo(BaseLPManager.WithdrawToParams(address(0), USDC, 1e18, pulls, swaps));
    }

    function test_withdrawTo_byOperator_reverts() public {
        vm.prank(owner);
        mgr.setOperator(bot, true);

        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](0);
        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](0);
        vm.prank(bot);
        vm.expectRevert(SingletonNFTOwned.NotOwnerNFT.selector);
        mgr.withdrawTo(BaseLPManager.WithdrawToParams(recipient, USDC, 1e18, pulls, swaps));
    }

    function test_withdrawTo_amountNotDelivered_reverts() public {
        uint256 amount = 1e18;
        BaseLPManager.WithdrawStep[] memory pulls = new BaseLPManager.WithdrawStep[](1);
        // Pull DAI/USDT but request USDC with no swaps ⇒ zero USDC credit ⇒ revert.
        pulls[0] =
            BaseLPManager.WithdrawStep({salt: _saltFor(1), liquidityToPull: mgr.positionOf(_saltFor(1)).liquidity});
        BaseLPManager.WithdrawSwap[] memory swaps = new BaseLPManager.WithdrawSwap[](0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseLPManager.AmountNotDelivered.selector, uint256(0), amount));
        mgr.withdrawTo(BaseLPManager.WithdrawToParams(recipient, USDC, amount, pulls, swaps));
    }
}
