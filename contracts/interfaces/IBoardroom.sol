// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IBoardroom {
    function sync() external;

    function allocateSeignioragePegToken(address _token, uint256 _amount) external;
}
