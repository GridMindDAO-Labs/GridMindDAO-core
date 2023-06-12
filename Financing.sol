// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interface/ITreasury.sol";
import "./interface/IPriceOracle.sol";
import "./interface/IStakingRewards.sol";
import "./interface/IInvitationRewards.sol";
import "./interface/IERC20Minable.sol";

contract Financing is Ownable, ReentrancyGuard,Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_DURATION = 28 days;
    uint256 public constant CLAIM_PERCENTAGE = 65;
    uint256 public constant STAKING_PERCENTAGE = 20;
    uint256 public constant TECH_FEE = 7;
    uint256 public constant BUILDER_FEE = 5;
    uint256 public constant FEE = 3;
    uint256 public minStaking = 10e18;
    uint24 public poolFee = 100;

    address public immutable USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public immutable WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address public immutable gmdToken;
    address public immutable inviteReward;
    address public immutable stakingReward;

    address public payee;
    address public builder;
    address public tech;
    address public treasury;
    address public oracle;

    mapping(address => uint256) public totalSavings;
    mapping(address => uint256) public savingsRate;
    mapping(address => uint256) public lastUpdateTime;
    mapping(address => uint256) public interestPerStored;
    
    bytes32[] private _orders; 
    mapping(bytes32 => uint) public ordersIndex;

    mapping(bytes32 => User) public users;

    event MinStakingUpdated(uint256 pre,uint256 newAmount);
    event PriceOracleUpdated(address indexed pre,address indexed newOracle);
    event TreasuryUpdated(address indexed pre,address indexed newTreasury);
    event PayeeUpdated(address indexed pre,address indexed newPayee);
    event BuilderUpdated(address indexed pre,address indexed newBuilder);
    event TechUpdated(address indexed pre,address indexed newTech);
    event PoolFeeUpdated(uint24 pre,uint24 newFee);
    event SavingsRateUpdated(address indexed token,uint256 preRate,uint256 newRate);
    event Deposited(bytes32 orderHash,address indexed token,address indexed account,uint256 amount);
    event Withdrawn(bytes32 orderHash,address indexed token,address indexed account,uint256 amount,uint256 interest);
    event UserPeriodFinishUpdated(bytes32 orderHash,address indexed token,uint256 _periodFinish);

    struct User {
        address account;
        address token;
        uint256 balance;
        uint256 value;
        uint256 interest;
        uint256 interestPerSavingsRateReleased;
        uint256 periodFinish;
        uint256 lastUpdateTime;
    }

    constructor(
        address _gmdToken,
        address _oracle,
        address _treasury,
        address _inviteReward,
        address _stakingReward,
        address _payee,
        address _builder,
        address _tech
    ) {
        oracle = _oracle;
        treasury = _treasury;
        gmdToken = _gmdToken;
        inviteReward = _inviteReward;
        stakingReward = _stakingReward;
        payee = _payee;
        builder = _builder;
        tech = _tech;
    }

    function orders() external view returns (bytes32[] memory) {
        return _orders;
    }

    function checkUpkeep() external view whenNotPaused
        returns (bool upkeepNeeded, bytes memory performData)
    {
        bytes32[] memory orderHashs = _getExpiredOrders();
        upkeepNeeded = orderHashs.length > 0;
        performData = abi.encode(orderHashs);
        return (upkeepNeeded, performData);
    }

    function earned(bytes32 orderHash) public view returns (uint256) {
        User memory user = users[orderHash];
        if (user.lastUpdateTime > user.periodFinish) {
            return user.interest;
        }
        return user.value.mul(
            interestPerToken(user.token)
            .add(interestPerStored[user.token])
            .sub(user.interestPerSavingsRateReleased)
        ).div(1e18).add(user.interest);
    }

    function interestPerToken(address token) public view returns (uint256) {
        if (totalSavings[token] > 0) {
            return block.timestamp.sub(lastUpdateTime[token])
                    .mul(savingsRate[token]);
        }
        return interestPerStored[token];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function performUpkeep(bytes calldata performData) external whenNotPaused {
        bytes32[] memory orderHashs = abi.decode(performData, (bytes32[]));
        _liquidate(orderHashs);
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

    function setPoolFee(uint24 newFee) external onlyOwner {
        emit PoolFeeUpdated(poolFee,newFee);
        poolFee = newFee;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "New address is the zero address");

        emit TreasuryUpdated(treasury,newTreasury);
        treasury = newTreasury;
    }

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "New address is the zero address");

        emit PriceOracleUpdated(oracle,newOracle);
        oracle = newOracle;
    }

    function setSavingsRate(address token,uint256 rate) external onlyOwner {
        _updateInterestPeriod(token);

        uint256 reward = rate.div(365).div(86400);
        uint256 pre = savingsRate[token];
        savingsRate[token] = reward;

        emit SavingsRateUpdated(token,pre,rate);
    }

    function setMinStaking(uint256 newAmount) external onlyOwner {
        emit MinStakingUpdated(minStaking,newAmount);
        minStaking = newAmount;
    }

    function deposit(address token,address inviter,uint256 amount) external payable nonReentrant {
        require(savingsRate[token] > 0,"Financing:savings rate is zero");
        require(amount > 0, "Financing:Amount must be greater than 0");
        
        address wtoken = token == address(0) ? WETH : token;
        uint256 price = _latestPrice(wtoken,USDT).mul(amount).mul(10**(uint256(18).sub(IERC20Minable(wtoken).decimals()))).div(1e18);
        require(price >= minStaking,"Financing:insufficient deposit price");

        totalSavings[token] += amount;

        bytes32 orderHash = keccak256(abi.encodePacked(_msgSender(), totalSavings[token], block.number));
        ordersIndex[orderHash] = _orders.length;
        _orders.push(orderHash);

        IInvitationRewards(inviteReward).stake(_msgSender(), inviter, price);

        IStakingRewards(stakingReward).createOrder(orderHash, _msgSender(),price);

        if (token == address(0)) {
            require(msg.value == amount, "Financing:Insufficient payment");
            Address.sendValue(payable(treasury), amount);
        }else {
            IERC20(token).safeTransferFrom(_msgSender(),address(treasury),amount);
        }

        User storage user = users[orderHash];
        user.account = _msgSender();
        user.token = token;

        _updateInterest(orderHash);
        
        user.periodFinish = REWARD_DURATION + block.timestamp;
        user.value += price;
        user.balance += amount;

        emit Deposited(orderHash, token, _msgSender(), amount);
    }

    function withdraw(bytes32 orderHash) external nonReentrant {
        User memory user = users[orderHash];
        require(user.account == _msgSender(),"Financing: Not authorized");
        
        uint256 earn = earned(orderHash);
        uint256 interest = IPriceOracle(oracle).lastestPrice(
            USDT,gmdToken,poolFee,0
        ).mul(earn).div(1e18);

        uint256 claimAmount = interest.mul(CLAIM_PERCENTAGE).div(100);
        uint256 stakingAmount = interest.mul(STAKING_PERCENTAGE).div(100);
        
        uint256 balance = user.balance;
        address token = user.token;
        
        ITreasury(treasury).claim(_msgSender(),claimAmount);
        ITreasury(treasury).claim(payee,interest.mul(FEE).div(100));
        ITreasury(treasury).claim(builder,interest.mul(BUILDER_FEE).div(100));
        ITreasury(treasury).claim(tech,interest.mul(TECH_FEE).div(100));
        ITreasury(treasury).withdraw(token,_msgSender(),balance);

        IInvitationRewards(inviteReward).unstake(_msgSender(),user.value);
        IInvitationRewards(inviteReward).notifyRewardAmount(_msgSender(),interest,earn);

        IStakingRewards(stakingReward).liquidate(orderHash);
        
        ITreasury(treasury).claim(stakingReward,stakingAmount);
        IStakingRewards(stakingReward).notifyRewardAmount(stakingAmount);

        totalSavings[token] -= balance;

        _removeOrder(orderHash);

        emit Withdrawn(orderHash, token, _msgSender(), balance, claimAmount);
    }

    function claim(bytes32 orderHash) external nonReentrant {
        User storage user = users[orderHash];
        require(user.account == _msgSender(),"Financing:invalidate order hash");
        
        _updateInterest(orderHash);
        
        uint256 interest = IPriceOracle(oracle).lastestPrice(
            USDT,gmdToken,poolFee,0
        ).mul(user.interest).div(1e18);
        uint256 claimAmount = interest.mul(CLAIM_PERCENTAGE).div(100);
        uint256 stakingAmount = interest.mul(STAKING_PERCENTAGE).div(100);
        
        ITreasury(treasury).claim(_msgSender(),claimAmount);
        ITreasury(treasury).claim(payee,interest.mul(FEE).div(100));
        ITreasury(treasury).claim(builder,interest.mul(BUILDER_FEE).div(100));
        ITreasury(treasury).claim(tech,interest.mul(TECH_FEE).div(100));
        ITreasury(treasury).claim(stakingReward,stakingAmount);

        IInvitationRewards(inviteReward).notifyRewardAmount(_msgSender(),interest,user.interest);
        IInvitationRewards(inviteReward).updateUserTeamPerformance(_msgSender());

        IStakingRewards(stakingReward).notifyRewardAmount(stakingAmount);
        
        user.interest = 0;

        emit Withdrawn(orderHash, user.token, _msgSender(), 0, claimAmount);
    }

    function updateUserPeriodFinish(bytes32 orderHash) external nonReentrant {
        User storage user = users[orderHash];
        require(user.account == _msgSender(),"Financing:invalidate order hash");
        require(block.timestamp < user.periodFinish,"Financing:finish");

        _updateInterest(orderHash);

        user.periodFinish = user.periodFinish.add(REWARD_DURATION);
        emit UserPeriodFinishUpdated(orderHash,_msgSender(),user.periodFinish);
    }

    function _liquidate(bytes32[] memory orderHashs) private {
        for(uint256 i = 0; i < orderHashs.length; i++) {
            _updateInterest(orderHashs[i]);
        }
    }

    function _updateInterest(bytes32 orderHash) private {
        User storage user = users[orderHash];
        _updateInterestPeriod(user.token);

        user.interest = earned(orderHash);
        user.interestPerSavingsRateReleased = interestPerStored[user.token];
        user.lastUpdateTime = block.timestamp;

        if (user.periodFinish > 0 && user.lastUpdateTime > user.periodFinish) {
            IStakingRewards(stakingReward).liquidate(orderHash);
        }
    }

    function _updateInterestPeriod(address token) private {
        interestPerStored[token] += interestPerToken(token);
        lastUpdateTime[token] = block.timestamp;
    }

    function _getExpiredOrders() private view returns (bytes32[] memory){
        bytes32[] memory watchList = _orders;
        bytes32[] memory orderHashs = new bytes32[](watchList.length);
        uint256 count = 0;
        for(uint256 i = 0; i < watchList.length; i++) {
            if (
                block.timestamp > users[watchList[i]].periodFinish &&
                users[watchList[i]].lastUpdateTime < users[watchList[i]].periodFinish
            ) {
                 orderHashs[count] = watchList[i];
                 count ++;
            }
        }

        if (count != watchList.length) {
            assembly {
                mstore(orderHashs, count)
            }
        }
        return orderHashs;
    }

    function _removeOrder(bytes32 orderHash) private {
        _orders[ordersIndex[orderHash]] = _orders[_orders.length-1];
        ordersIndex[_orders[_orders.length-1]] = ordersIndex[orderHash];
        _orders.pop();

        delete ordersIndex[orderHash];
        delete users[orderHash];
    }

    function _latestPrice(address tokenA,address tokenB) private returns (uint256) {
        if (tokenA == tokenB) {
            return 1e18;
        }
        return IPriceOracle(oracle).lastestPrice(tokenA,tokenB,poolFee,0);
    }
}