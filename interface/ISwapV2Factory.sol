// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface ISwapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
}