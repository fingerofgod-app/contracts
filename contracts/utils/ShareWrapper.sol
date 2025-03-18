// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ShareWrapper
 * @dev A lightweight wrapper for staking an ERC20-based "share" token.
 *      Users can stake tokens, which increases the total staked balance,
 *      and can withdraw or claim them later. This contract is meant to be
 *      inherited by a higher-level Boardroom-like contract.
 */
contract ShareWrapper {
    using SafeERC20 for IERC20;

    /// @notice The share token that users stake.
    IERC20 public share;

    /// @dev Tracks the total staked supply of the share token.
    uint256 private _totalStaked;

    /// @dev Tracks each user's staked balance.
    mapping(address => uint256) private _stakedBalances;

    /**
     * @notice Returns the total staked supply of the share token.
     */
    function totalSupply() public view returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice Returns the staked balance of a given account.
     * @param account The address of the user.
     */
    function balanceOf(address account) public view returns (uint256) {
        return _stakedBalances[account];
    }

    /**
     * @notice Allows a user to stake a specified amount of the share token.
     *         The contract adjusts for any potential deflationary token behavior
     *         by measuring the contract's share balance before and after transfer.
     * @param amount The amount of the share token to stake.
     */
    function stake(uint256 amount) public virtual {
        uint256 previousBalance = share.balanceOf(address(this));
        share.safeTransferFrom(msg.sender, address(this), amount);

        // Recalculate the actual transferred amount in case of deflationary token mechanics.
        amount = share.balanceOf(address(this)) - previousBalance;

        _totalStaked += amount;
        _stakedBalances[msg.sender] += amount;
    }

    /**
     * @dev Internal function that reduces the caller's staked balance without
     *      transferring tokens back to them. This is intended for "pending withdraw"
     *      logic where the tokens remain in the contract until a finalize step.
     * @param amount The amount to remove from the caller's staked balance.
     */
    function _withdraw(uint256 amount) internal virtual {
        uint256 userStakedBalance = _stakedBalances[msg.sender];
        require(userStakedBalance >= amount, "ShareWrapper: withdraw request exceeds staked balance");

        _totalStaked -= amount;
        _stakedBalances[msg.sender] = userStakedBalance - amount;
    }

    /**
     * @dev Internal function that restores a user's staked balance after a withdraw
     *      request has been canceled. This effectively re-stakes the tokens for the user.
     * @param amount The amount to re-stake to the caller's balance.
     */
    function _cancelWithdraw(uint256 amount) internal virtual {
        _totalStaked += amount;
        _stakedBalances[msg.sender] += amount;
    }

    /**
     * @dev Internal function that transfers share tokens from the contract
     *      to the caller, finalizing the withdrawal process.
     * @param amount The amount of share tokens to transfer to the user.
     */
    function _claimPendingWithdraw(uint256 amount) internal virtual {
        share.safeTransfer(msg.sender, amount);
    }
}
