
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface ITreasury {
    function withdraw(address token,address to,uint256 amount) external;
    function claim(address to, uint256 amount) external;
}