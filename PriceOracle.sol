// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.6;

import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";

interface IERC20 {
    function decimals() external  view returns (uint256);
}

contract PriceOracle {
    IUniswapV3Factory public immutable FACTORY = 
        IUniswapV3Factory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);

    function getSqrtTwapX96(
        address uniswapV3Pool,
        uint32 twapInterval
    ) public view returns (uint160 sqrtPriceX96) {
        if (twapInterval == 0) {
            (sqrtPriceX96, , , , , , ) = IUniswapV3Pool(uniswapV3Pool).slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = twapInterval;
            secondsAgos[1] = 0; 

            (int56[] memory tickCumulatives, ) = IUniswapV3Pool(uniswapV3Pool).observe(secondsAgos);

            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / twapInterval)
            );
        }
    }

    function lastestPrice(
        address token0,
        address token1,
        uint24 fee,
        uint32 interval
    ) public view returns (uint256) {
        address pool = FACTORY.getPool(
            token0 ,token1 ,fee 
        );

        require(pool != address(0), "Pool does not exsist") ;

        (uint256 token0Decimals,uint256 token1Decimals) = _getDecimals(
            IUniswapV3Pool(pool).token0(),
            IUniswapV3Pool(pool).token1()
        );

        uint160 sqrtPriceX96 = getSqrtTwapX96(pool, interval);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 price0 = FullMath.mulDiv(
            priceX96, 10**(token0Decimals + 18 - token1Decimals), FixedPoint96.Q96);

        if (token0 == IUniswapV3Pool(pool).token0()) return price0;
        else return FullMath.mulDiv(10**18, 10**18, price0);
    }

    function _getDecimals(
        address token0,
        address token1 
    ) public view returns (uint256 token0Decimals, uint256 token1Decimals) {
        return (IERC20(token0).decimals(), IERC20(token1).decimals());
    }
}