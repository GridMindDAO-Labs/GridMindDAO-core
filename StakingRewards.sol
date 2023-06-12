// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract StakingRewards is Ownable,AccessControl,ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IERC20 public gmdToken;

    address public payee;
    address public builder;
    address public tech;
    
    address public immutable USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    uint256 public constant TECH_FEE = 7;
    uint256 public constant BUILDER_FEE = 5;
    uint256 public constant FEE = 3;
    uint256 public constant CLAIM_PERCENTAGE = 65;
    uint256 public constant STAKING_PERCENTAGE = 20;

    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 28 days;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(bytes32 => User) public userOrders;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) private _balances;
        
    uint256 private _totalSupply;
    
    event PayeeUpdated(address indexed pre,address indexed newPayee);
    event BuilderUpdated(address indexed pre,address indexed newBuilder);
    event TechUpdated(address indexed pre,address indexed newTech);
    event RewardAdded(uint256 reward);
    event Withdrawn(bytes32 order,address indexed user, uint256 amount); 
    event RewardClaimed(address indexed user, uint256 amount);  
    event OrderCreated(bytes32 order,address indexed user,uint256 _amount);

    struct User {
        address account;
        uint256 balance;
    }

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    constructor(
        address _gmdToken,
        address _payee,
        address _builder,
        address _tech
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(EXECUTOR_ROLE, _msgSender());

        gmdToken = IERC20(_gmdToken);
        payee = _payee;
        builder = _builder;
        tech = _tech;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }
    
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }
    
    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
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

    function createOrder(bytes32 orderHash, address account,uint256 _amount) external nonReentrant onlyRole(EXECUTOR_ROLE) updateReward(account) {
       if (userOrders[orderHash].account == address(0)) {
            userOrders[orderHash] = User(account,_amount);

            _totalSupply = _totalSupply.add(_amount);    
            _balances[account] = _balances[account].add(_amount);
            
            emit OrderCreated(orderHash,account,_amount);
        }
    }

    function liquidate(bytes32 orderHash) external nonReentrant onlyRole(EXECUTOR_ROLE) {
        User memory user = userOrders[orderHash];
        uint256 amount = user.balance;
        address account = user.account;
        if (amount > 0) {
            _updateReward(account);  
            _totalSupply = _totalSupply.sub(amount);        
            _balances[account] = _balances[account].sub(amount); 
            if (block.timestamp > periodFinish) {
                rewardRate = 0;
            }
        }
        emit Withdrawn(orderHash, account, amount);
        delete userOrders[orderHash];
    }

    function claimRewards() public nonReentrant updateReward(_msgSender()) {
        uint256 reward = rewards[_msgSender()];
        if (reward > 0) {
            rewards[_msgSender()] = 0;
            uint256 paid = reward.mul(CLAIM_PERCENTAGE).div(100);
            gmdToken.safeTransfer(_msgSender(), paid);
            gmdToken.safeTransfer(payee, reward.mul(FEE).div(100));
            gmdToken.safeTransfer(tech, reward.mul(TECH_FEE).div(100));
            gmdToken.safeTransfer(builder, reward.mul(BUILDER_FEE).div(100));
            emit RewardClaimed(_msgSender(), paid);

            _notifyRewardAmount(reward.mul(STAKING_PERCENTAGE).div(100));
        }
    }

    function notifyRewardAmount(uint256 reward) external onlyRole(EXECUTOR_ROLE) {
        _notifyRewardAmount(reward);
    }

    function _notifyRewardAmount(uint256 reward) private updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function _updateReward(address account) private {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }
}
