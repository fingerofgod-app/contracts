// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../interfaces/IPool.sol";

/**
 * @title PoolOracle
 * @notice Provides TWAP price consultations for a liquidity pool (pair) using a new Pair implementation.
 * @dev This contract reads observations from the pool to compute a time-weighted average price (TWAP).
 * It also allows updating the pool state by calling sync.
 */
contract PoolOracle {
    // The two tokens in the pair.
    address public token0;
    address public token1;

    // The liquidity pool (pair) from which the oracle reads price data.
    IPool public pair;

    /**
     * @notice Initializes the PoolOracle with the given pair.
     * @param _pair The liquidity pool contract.
     */
    constructor(IPool _pair) {
        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();

        // Check that the pair has non-zero reserves.
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "PoolOracle: No reserves");
    }

    /**
     * @notice Updates the pool's internal state by calling sync.
     */
    function update() external {
        pair.sync();
    }

    /**
     * @notice Consults the oracle for a quote based on historical data.
     * @param _token The token address for which to get the quote (must be token0 or token1).
     * @param _amountIn The amount of input token.
     * @return amountOut The quoted output amount.
     * @dev Uses a granularity of 12 observations (e.g. 6 hours if each observation is 30min).
     */
    function consult(address _token, uint256 _amountIn) external view returns (uint256 amountOut) {
        if (_token == token0 || _token == token1) {
            amountOut = _quote(_token, _amountIn, 12);
        } else {
            revert("PoolOracle: Invalid token");
        }
    }

    /**
     * @notice Returns the time-weighted average price (TWAP) for a given token.
     * @param _token The token address for which to get the TWAP (must be token0 or token1).
     * @param _amountIn The amount of input token.
     * @return amountOut The TWAP quoted output amount.
     * @dev Uses a granularity of 2 observations (e.g. 1 hour if each observation is 30min).
     */
    function twap(address _token, uint256 _amountIn) external view returns (uint256 amountOut) {
        if (_token == token0 || _token == token1) {
            amountOut = _quote(_token, _amountIn, 2);
        } else {
            revert("PoolOracle: Invalid token");
        }
    }

    /**
     * @dev Internal function to obtain a price quote from the pool.
     * @param tokenIn The input token address.
     * @param amountIn The input token amount.
     * @param granularity The number of historical observations to use.
     * @return amountOut The quoted output amount.
     * @notice The granularity parameter effectively sets the time window for TWAP calculations.
     * For example, if each observation represents 30 minutes, a granularity of 12 gives a 6-hour window.
     */
    function _quote(address tokenIn, uint256 amountIn, uint256 granularity) internal view returns (uint256 amountOut) {
        uint256 observationLength = pair.observationLength();
        require(granularity <= observationLength, "PoolOracle: Not enough observations");

        amountOut = pair.quote(tokenIn, amountIn, granularity);
    }
}
