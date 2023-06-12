// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interface/IStakingRewards.sol";

contract InvitationRewards is Ownable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IStakingRewards public immutable STAKING;

    address public gmdToken;
    address public payee;
    address public builder;
    address public tech;

    uint256 public constant REWARD_DURATION = 28 days;
    uint256 public constant CLAIM_PERCENTAGE = 65;
    uint256 public constant STAKING_PERCENTAGE = 20;
    uint256 public constant TECH_FEE = 7;
    uint256 public constant BUILDER_FEE = 5;
    uint256 public constant FEE = 3;
    uint256 public constant DENOMINATOR = 10000;
    uint256 public rate = 200;

    uint256[4] public communityThresholds = [1, 10, 20, 30];
    uint256[4] public teamPerformanceThresholds = [0, 10000e18, 80000e18, 350000e18];
    uint256[4] public rewardPercentageLimits = [12000, 15000, 18000, 20000]; 

    mapping(address => User) public users;
    mapping(address => Level) public levels;
    
    event PayeeUpdated(address indexed pre,address indexed newPayee);
    event BuilderUpdated(address indexed pre,address indexed newBuilder);
    event TechUpdated(address indexed pre,address indexed newTech);
    event RewardClaimed(address indexed account, uint256 amount);
    event RewardAdded(address indexed staker, uint256 reward, uint256 _value);
    event Staked(address indexed staker, address _referrer, uint256 amount);
    event UnStaked(address indexed staker, address _referrer, uint256 amount);
    event RateUpdated(uint256 old,uint256 newRate);
    event ThresholdsUpdated(uint256[4] oldThresholds,uint256[4] newThresholds);
    event CommunityThresholdsUpdated(uint256[4] oldThresholds,uint256[4] newThresholds);
    event RewardPercentageLimitsUpdated(uint256[4] oldPercentages,uint256[4] newPercentages);
    event CommunityLevelUpdated(address indexed user, uint256 oldLevel, uint256 newLevel);
    event TeamPerformanceUpdated(address indexed user, address indexed referrer, int256 performanceDifference);

    struct User { 
        uint256 stakedAmount;
        uint256 invitedUsers;
        uint256 teamPerformance;
        uint256 lastTeamPerformance;
        uint256 liquidity;
        uint256 earned;
        uint256 lastUpdateTime;
        uint256 periodFinish;
        uint256 communityLevel;
        uint256 value;
        address referrer;
        bool hasStaked;
    }

    struct Level {
        uint256 regularCommunities;
        uint256 juniorCommunities;
        uint256 intermediateCommunities;
        uint256 seniorCommunities;
    }

    constructor(
        address _gmdToken,
        address staking,
        address _payee,
        address _builder,
        address _tech
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(EXECUTOR_ROLE, _msgSender());

        gmdToken = _gmdToken;
        STAKING = IStakingRewards(staking);
        payee = _payee;
        builder = _builder;
        tech = _tech;
    }

    function earned(address account) public view returns (uint256) {
        return _calculateReward(account,block.timestamp);
    }

    function setPayee(address newPayee) external onlyOwner {
        require(newPayee != address(0), "New address is the zero address");

        emit PayeeUpdated(payee,newPayee);
        payee = newPayee;
    }

    function setBuilder(address newBuilder) external onlyOwner {
        require(newBuilder != address(0), "New address is the zero address");

        emit BuilderUpdated(builder,newBuilder);
        builder = newBuilder;
    }

    function setTech(address newTech) external onlyOwner {
        require(newTech != address(0), "New address is the zero address");

        emit TechUpdated(tech,newTech);
        tech = newTech;
    }

    function setRate(uint256 newRate) external onlyOwner {
        emit RateUpdated(rate,newRate);
        rate = newRate;
    }

    function setTeamPerformanceThresholds(uint256[4] memory _thresholds) external onlyOwner {
        emit ThresholdsUpdated(teamPerformanceThresholds,_thresholds);
        teamPerformanceThresholds = _thresholds;
    }

    function setCommunityThresholds(uint256[4] memory newThresholds) external onlyOwner {
        emit CommunityThresholdsUpdated(communityThresholds,newThresholds);
        communityThresholds = newThresholds;
    }

    function setRewardPercentageLimits(uint256[4] memory newPercentageLimits) external onlyOwner {
        emit RewardPercentageLimitsUpdated(rewardPercentageLimits,newPercentageLimits);
        rewardPercentageLimits = newPercentageLimits;
    }

    function updateUserTeamPerformance(address _user) public {
        if (_user == address(0)) {
            return;
        }
        
        _updateCommunityLevel(_user);

        User storage user = users[_user];
        address referrer = user.referrer;

        if (referrer == address(0)) {
            return;
        }

        User storage referrerUser = users[referrer];
        uint256 updatedPerformance = user.stakedAmount + user.teamPerformance;
        int256 performanceDifference = int256(updatedPerformance) - int256(user.lastTeamPerformance);

        if (performanceDifference > 0) {
            referrerUser.teamPerformance += uint256(performanceDifference);
        } else if (performanceDifference < 0) {
            referrerUser.teamPerformance -= uint256(-performanceDifference);
        }

        user.lastTeamPerformance = updatedPerformance;

        emit TeamPerformanceUpdated(_user, referrer, performanceDifference);

        _updateCommunityLevel(referrer);
    }
    
    function stake(address staker,address _referrer,uint256 _amount) external onlyRole(EXECUTOR_ROLE) {        
        users[staker].stakedAmount += _amount;

        if (!users[staker].hasStaked) {
            users[staker].hasStaked = true;

            if (_referrer != address(0)) {
                require(users[_referrer].hasStaked, "InvitationRewards:Referrer must have staked before");
                users[staker].referrer = _referrer;
                users[_referrer].invitedUsers += 1;
            }
        }
        
        updateUserTeamPerformance(staker);

        emit Staked(staker,users[staker].referrer,_amount);
    }

    function notifyRewardAmount(address staker,uint256 reward,uint256 _value) external onlyRole(EXECUTOR_ROLE) {
        _updateRewardInfo(staker,reward,_value);
        emit RewardAdded(staker, reward, _value);
    }

    function unstake(address staker,uint256 _amount) external onlyRole(EXECUTOR_ROLE) {
        require(users[staker].stakedAmount >= _amount, "InvitationRewards:Not enough staked tokens");
        User storage user = users[staker];
        user.stakedAmount -= _amount;
        
        updateUserTeamPerformance(staker);
        
        emit UnStaked(staker, user.referrer, _amount);
    }

    function claimRewards(uint256 _amount) external nonReentrant {
        uint256 reward = _calculateReward(_msgSender(),block.timestamp);
        require(_amount >= 0 && reward >= _amount, "InvitationRewards:No rewards available");
        require(IERC20(gmdToken).balanceOf(address(this)) >= _amount, "InvitationRewards:Not enough GMD tokens in the pool");

        User storage user = users[_msgSender()];
        user.lastUpdateTime = block.timestamp;
        user.earned = reward - _amount;

        uint256 claimAmount = _amount.mul(CLAIM_PERCENTAGE).div(100);
        
        IERC20(gmdToken).safeTransfer(_msgSender(), claimAmount);
        IERC20(gmdToken).safeTransfer(payee, _amount.mul(FEE).div(100));
        IERC20(gmdToken).safeTransfer(builder, _amount.mul(BUILDER_FEE).div(100));
        IERC20(gmdToken).safeTransfer(tech, _amount.mul(TECH_FEE).div(100));

        IERC20(gmdToken).safeTransfer(address(STAKING),_amount.mul(STAKING_PERCENTAGE).div(100));
        STAKING.notifyRewardAmount(_amount.mul(STAKING_PERCENTAGE).div(100));

        emit RewardClaimed(_msgSender(), claimAmount);

        updateUserTeamPerformance(_msgSender());
    }

    function _calculateReward(address account,uint256 _timestamp) private view returns (uint256) {
        User memory user = users[account];
        if (user.periodFinish == 0 || user.lastUpdateTime > user.periodFinish) {
            return 0;
        }
         
        uint256 timeElapsed = Math.min(_timestamp, user.periodFinish).sub(user.lastUpdateTime);

        uint256 reward = user.liquidity.
            mul(timeElapsed).
            div(REWARD_DURATION).
            add(user.earned);
        return reward;
    }

    function _updateCommunityLevel(address _user) private {
        User storage user = users[_user];
        
        uint256 previousLevel = user.communityLevel;
        for (uint256 i = 4; i > 0; i--) {
            bool levelUpgraded = false;
            if (user.invitedUsers >= communityThresholds[i - 1] && user.teamPerformance >= teamPerformanceThresholds[i - 1]) {
                if (i == 3 && levels[_user].juniorCommunities >= 3) {
                    levelUpgraded = true;
                } else if (i == 4 && levels[_user].intermediateCommunities >= 3) {
                    levelUpgraded = true;
                } else {
                    levelUpgraded = true;
                }
            }

            if (levelUpgraded) {
                user.communityLevel = i;
                break;
            }
        }

        if (previousLevel != user.communityLevel) {
            emit CommunityLevelUpdated(_user, previousLevel, user.communityLevel);

            if (user.referrer != address(0)) {
                Level storage level = levels[user.referrer];

                if (previousLevel == 1) {
                    level.regularCommunities -= 1;
                }else if (previousLevel == 2) {
                    level.juniorCommunities -= 1;
                } else if (previousLevel == 3) {
                    level.intermediateCommunities -= 1;
                } else if (previousLevel == 4) {
                    level.seniorCommunities -= 1;
                }

                if (user.communityLevel == 1) {
                    level.regularCommunities += 1;
                } else if (user.communityLevel == 2) {
                    level.juniorCommunities += 1;
                } else if (user.communityLevel == 3) {
                    level.intermediateCommunities += 1;
                } else if (user.communityLevel == 4) {
                    level.seniorCommunities += 1;
                } 
            }
        }
    }

    function _updateRewardInfo(address _user,uint256 amount,uint256 _value) private {
        User storage user = users[_user];
        user.earned = _calculateReward(_user,block.timestamp);
        user.lastUpdateTime = block.timestamp;
        
        if (user.referrer != address(0)) {
            User storage referrer = users[user.referrer];
            referrer.value = referrer.value.add(_value);
        }

        if (user.communityLevel == 0) {
            return;
        }

        uint256 maxAmount = rate.mul(100e18).mul(rewardPercentageLimits[user.communityLevel - 1]).div(DENOMINATOR);
        uint256 rewardPercentage = user.value <= maxAmount ? user.value.div(rate) : maxAmount.div(rate);
        amount = amount.mul(rewardPercentage).div(100e18);

        uint256 leftover = _calculateReward(_user,user.periodFinish);
        user.liquidity = amount.add(leftover);

        user.periodFinish = block.timestamp.add(REWARD_DURATION);
    }
}