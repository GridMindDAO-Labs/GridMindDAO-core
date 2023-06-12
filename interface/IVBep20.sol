// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IVBep20 {
    function mint(uint mintAmount) external returns (uint256);
    function mint() external payable;
    function redeem(uint redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint);
    function exchangeRateCurrent() external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function borrow(uint borrowAmount) external returns (uint256);
    function repayBorrow(uint repayAmount) external returns (uint256);
    function repayBorrow() payable external;
    function borrowBalanceCurrent(address account) external returns (uint256);
}