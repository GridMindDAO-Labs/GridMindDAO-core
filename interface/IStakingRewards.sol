// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IStakingRewards {
    function createOrder(bytes32 orderHash, address account,uint256 _amount) external;
    function stake(bytes32 orderHash, address account) external;
    function notifyRewardAmount(uint256 reward) external;
    function liquidate(bytes32 orderHash) external;
}