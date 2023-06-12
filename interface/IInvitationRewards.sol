// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IInvitationRewards {
    function updateUserTeamPerformance(address _user) external;
    function stake(address staker,address _referrer,uint256 _amount) external;
    function unstake(address staker,uint256 _amount) external;
    function notifyRewardAmount(address staker,uint256 reward,uint256 _value) external;
}