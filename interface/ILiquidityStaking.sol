// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface ILiquidityStaking {
    function notifyRewardAmount(uint256 reward,uint256 duration) external;
}