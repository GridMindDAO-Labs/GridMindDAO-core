// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IUnitroller {
    function enterMarkets(address[] calldata vTokens) external returns (uint[] memory);
    function exitMarket(address vToken) external returns (uint);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);

}