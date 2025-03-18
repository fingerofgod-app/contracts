// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IUFragments {
    function rebase(uint256 epoch, int256 supplyDelta) external returns (uint256);

    function totalSupply() external view returns (uint256);

    function gonsPerFragment() external view returns (uint256);

    function scaledBalanceOf(address who) external view returns (uint256);

    function scaledTotalSupply() external returns (uint256);
}
