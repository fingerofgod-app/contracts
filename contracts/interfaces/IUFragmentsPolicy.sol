// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IUFragmentsPolicy {
    function epoch() external view returns (uint256);

    function rebase() external returns (uint256);
}
