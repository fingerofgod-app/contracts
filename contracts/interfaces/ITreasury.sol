// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "./IEpoch.sol";

interface ITreasury is IEpoch {
    function getPegTokenPrice(address _token) external view returns (uint256);

    function getPegTokenUpdatedPrice(address _token) external view returns (uint256);

    function getPegTokenLockedBalance(address _token) external view returns (uint256);

    function getPegTokenCirculatingSupply(address _token) external view returns (uint256);

    function getPegTokenExpansionRate(address _token) external view returns (uint256);

    function getPegTokenExpansionAmount(address _token) external view returns (uint256);

    function boardroom() external view returns (address);

    function boardroomSharedPercent() external view returns (uint256);

    function pegStabilizationReserves() external view returns (address);

    function pegStabilizationReservesSharedPercent() external view returns (uint256);

    function devFund() external view returns (address);

    function devFundSharedPercent() external view returns (uint256);

    function isTokenPrinter(address token, address account) external view returns (bool);

    function priceOne() external view returns (uint256);

    function priceCeiling() external view returns (uint256);

    function fog() external view returns (address);

    function fogOracle() external view returns (address);
}
