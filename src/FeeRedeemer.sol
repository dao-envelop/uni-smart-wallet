// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FeeRedeemer
/// @notice Cashes out the `StableLPManager` protocol fee. The fee accrues as ERC-6909 **claims** inside
/// the PoolManager to `PROTOCOL_TREASURY` (a `mint`, not an ERC-20 transfer — so a stablecoin
/// blocklist/pause on the treasury can never revert the LP exit path and lock principal). This contract
/// is meant to **be** that treasury: deploy it first and pass its address as `treasury_` to the
/// `StableLPManager` implementation. The protocol owner then converts the accrued claims to real
/// ERC-20 / native via the only legal route — `unlock → burn(claims) → take`.
/// @dev Because the claims accrue to this contract, `burn(address(this), …)` needs no ERC-6909 approval.
contract FeeRedeemer is IUnlockCallback, Ownable {
    using CurrencyLibrary for Currency;

    /// @notice The V4 PoolManager holding this contract's ERC-6909 fee claims.
    IPoolManager public immutable POOL_MANAGER;

    error NotPoolManager();

    /// @notice Emitted for each currency redeemed from claims to ERC-20 / native.
    /// @param currency The redeemed currency.
    /// @param to Recipient of the redeemed tokens.
    /// @param amount Amount redeemed.
    event Redeemed(Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Deploy the redeemer (meant to be the `StableLPManager` PROTOCOL_TREASURY).
    /// @param poolManager_ The V4 PoolManager where the fee claims accrue.
    /// @param owner_ The protocol owner allowed to call {redeem}.
    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) {
        POOL_MANAGER = poolManager_;
    }

    /// @notice The redeemable protocol fee: this contract's ERC-6909 claim balance for `currency`.
    /// @param currency The currency to query.
    /// @return The redeemable claim balance.
    function claimable(Currency currency) external view returns (uint256) {
        return POOL_MANAGER.balanceOf(address(this), currency.toId());
    }

    /// @notice Redeem the full accrued claim of each `currencies[i]` to `to` as ERC-20 / native.
    /// Owner-only.
    /// @dev The caller supplies the list (the manager's `managedStables`) — the PoolManager cannot
    /// enumerate a holder's claims on-chain. Skips currencies with a zero balance.
    /// @param currencies The currencies to redeem (typically the manager's `managedStables`).
    /// @param to Recipient of the redeemed ERC-20 / native tokens.
    function redeem(Currency[] calldata currencies, address to) external onlyOwner {
        POOL_MANAGER.unlock(abi.encode(currencies, to));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev PoolManager unlock callback: burns this contract's claims and `take`s the tokens to `to`.
    /// Reverts unless called by the PoolManager.
    /// @param data ABI-encoded `(Currency[] currencies, address to)`.
    /// @return Empty bytes.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (Currency[] memory currencies, address to) = abi.decode(data, (Currency[], address));
        for (uint256 i = 0; i < currencies.length; ++i) {
            Currency c = currencies[i];
            uint256 bal = POOL_MANAGER.balanceOf(address(this), c.toId());
            if (bal == 0) continue;
            // burn our own claims → +bal credit delta; `take` pays it out (ERC-20/native) → nets to 0.
            POOL_MANAGER.burn(address(this), c.toId(), bal);
            POOL_MANAGER.take(c, to, bal);
            emit Redeemed(c, to, bal);
        }
        return "";
    }

    /// @notice Accept native when a native-currency redemption routes ETH back to this contract.
    receive() external payable {}
}
