 
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IPriceOracle {
    function lastestPrice(
            address token0,
            address token1,
            uint24 fee,
            uint32 interval
    ) external returns (uint256);
}