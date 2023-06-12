// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import './interface/INonfungiblePositionManager.sol';
import "./interface/IUniswapV3Pool.sol";
import "./interface/IUniswapV3Factory.sol";
import "./interface/IERC20Minable.sol";
import "./interface/IERC20Burnable.sol";

contract LiquidityStaking is Ownable,AccessControl,ReentrancyGuard,ERC721Holder {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    
    IUniswapV3Factory public immutable FACTORY = 
        IUniswapV3Factory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);

    INonfungiblePositionManager public positionManager;
    IERC721 public nft;

    address public payee;
    address public builder;
    address public tech;
    address public gmdToken;
    address public immutable lpToken;
  
    address public immutable USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    uint256 public rewardRate = 0;
    uint256 public periodFinish = 0;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public constant TECH_FEE = 7;
    uint256 public constant BUILDER_FEE = 5;
    uint256 public constant FEE = 3;
    uint256 public constant CLAIM_PERCENTAGE = 85;
    uint256 public constant DENOMINATOR = 10000;
    uint256 public rate = 100000000;
    uint24 public poolFee = 100;
    
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) private _balances;
    mapping(bytes32 => PositionDeposit) public deposits;

    uint256 private _totalSupply;
    
    struct PositionDeposit {
        address account;
        uint256 liquidity;
        uint256 tokenId;
        uint256 amount;
    }

    event PoolFeeUpdated(uint24 pre,uint24 newFee);
    event PayeeUpdated(address indexed pre,address indexed newPayee);
    event BuilderUpdated(address indexed pre,address indexed newBuilder);
    event TechUpdated(address indexed pre,address indexed newTech);
    event RateUpdated(uint256 oldRate,uint256 newRate);
    event RewardAdded(uint256 reward,uint256 duration);
    event Deposited(bytes32 positionId,address indexed account,uint256 tokenId,uint256 liquidity,uint256 amount);
    event Withdrawn(bytes32 positionId,address indexed account,uint256 tokenId,uint256 liquidity,uint256 amount); 
    event RewardClaimed(address indexed account, uint256 amount);
    event LiquidityAdded(address indexed account, uint256 tokenId); 

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    constructor(
        address _gmdToken,
        address _lpToken,
        address _positionManager,
        address _payee,
        address _builder,
        address _tech
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(EXECUTOR_ROLE, _msgSender());

        gmdToken = _gmdToken;
        lpToken = _lpToken;
        positionManager = INonfungiblePositionManager(_positionManager);
        nft = IERC721(_positionManager);
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

    function isValidNftPosition(uint256 tokenId) public view returns (bool) {
        (, , , , uint24 _fee, int24 tickLower, int24 tickUpper, , , , , ) = positionManager.positions(tokenId);
        
        if (_fee != poolFee) {
            return false;
        }

        IUniswapV3Pool pool = IUniswapV3Pool(FACTORY.getPool(
            gmdToken ,USDT ,_fee
        ));
        
        (, int24 currentTick, , , , , ) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        
        bool validTicks = (tickLower % tickSpacing == 0) && (tickUpper % tickSpacing == 0);
        
        bool withinRange = (tickLower <= currentTick) && (currentTick <= tickUpper);
        
        return validTicks && withinRange;
    }

    function setPoolFee(uint24 newFee) external onlyOwner {
        emit PoolFeeUpdated(poolFee,newFee);
        poolFee = newFee;
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

    function setRate(uint256 newRate) public onlyRole(EXECUTOR_ROLE) {
        emit RateUpdated(rate,newRate);
        rate = newRate;
    }

    function deposit(uint256 tokenId) public nonReentrant updateReward(_msgSender()) {
        require(isValidNftPosition(tokenId),"LiquidityStaking:Invilidate tick");

        nft.safeTransferFrom(_msgSender(),address(this),tokenId);
        
        uint128 liquidity;
        bytes32 _positionId;
        {
            (,,
                address token0,
                address token1,
                uint24 _fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 _liquidity,
                ,,,
            ) = positionManager.positions(tokenId);
            liquidity = _liquidity;
            _positionId = keccak256(abi.encodePacked(token0, token1, _fee, tickLower, tickUpper,block.timestamp));
            require(
                (token0 == address(gmdToken) && token1 == address(USDT)) ||
                (token0 == address(USDT) && token1 == address(gmdToken)),
                "LiquidityStaking:Invalid liquidity token pair"
             );
        }
        uint256 userShared = uint256(liquidity);
        _totalSupply = _totalSupply.add(userShared);    
        _balances[_msgSender()] = _balances[_msgSender()].add(userShared);

        PositionDeposit storage _deposit = deposits[_positionId];
        _deposit.liquidity += liquidity;
        _deposit.account = _msgSender();
        _deposit.tokenId = tokenId;

        uint256 amount = liquidity * rate / DENOMINATOR;
        _deposit.amount = amount;

        IERC20Minable(lpToken).mint(_msgSender(),amount);
      
        emit Deposited(_positionId, _msgSender(), tokenId, liquidity,amount);
    }

    function withdraw(bytes32 positionId) public nonReentrant {
        require(deposits[positionId].account == _msgSender(),"LiquidityStaking:Invalid user");
        
        uint256 liquidity = deposits[positionId].liquidity;       
        require(_balances[_msgSender()] >= liquidity, "LiquidityStaking:Not enough LP shares");

        uint256 amount = deposits[positionId].amount;
        require(IERC20(lpToken).allowance(_msgSender(),address(this)) >= amount,"LiquidityStaking:lptoken insufficient allowance");
        IERC20Burnable(lpToken).burnFrom(_msgSender(),amount);

        _updateReward(_msgSender());
        _totalSupply = _totalSupply.sub(liquidity);        
        _balances[_msgSender()] = _balances[_msgSender()].sub(liquidity); 

        uint256 tokenId = deposits[positionId].tokenId;
        nft.safeTransferFrom(address(this), _msgSender(), tokenId);
        
        emit Withdrawn(positionId,_msgSender(),tokenId,liquidity,amount);
        delete deposits[positionId];
    }
    
    function claimRewards() public nonReentrant updateReward(_msgSender()) {
        uint256 reward = rewards[_msgSender()];
        if (reward > 0) {
            rewards[_msgSender()] = 0;
            
            uint256 claimAmount = reward.mul(CLAIM_PERCENTAGE).div(100);
            
            IERC20(gmdToken).safeTransfer(_msgSender(), claimAmount);
            IERC20(gmdToken).safeTransfer(payee, reward.mul(FEE).div(100));
            IERC20(gmdToken).safeTransfer(builder, reward.mul(BUILDER_FEE).div(100));
            IERC20(gmdToken).safeTransfer(tech, reward.mul(TECH_FEE).div(100));
            emit RewardClaimed(_msgSender(), claimAmount);
        }
    }

    function exit(bytes32 positionId) external {
        withdraw(positionId);
        claimRewards();
    }

    function notifyRewardAmount(uint256 reward,uint256 duration) external updateReward(address(0)) onlyRole(EXECUTOR_ROLE) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(duration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(duration);
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(duration);
        emit RewardAdded(reward,duration);
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