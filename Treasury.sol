// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import './interface/INonfungiblePositionManager.sol';
import "./interface/ISwapV2Router.sol";
import "./interface/ISwapV2Factory.sol";
import "./interface/IUnitroller.sol";
import "./interface/IVBep20.sol";
import "./interface/IWETH.sol";
import "./interface/ILiquidityStaking.sol";

contract Treasury is Ownable,AccessControl,ERC721Holder {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    uint256 public constant DENOMINATOR = 10000;
    uint256 public stakingTransferred = 0;
    uint256 public invitationTransferred = 0;
    uint256 public stakingRate = 1000;
    uint256 public invitationRate = 2000;

    address public uniswapV2Router;
    address public pancakeV2Router;

    address public uniswapV3Router;
    address public pancakeV3Router;

    address public uniPositionManager;
    address public pancakePositionManager;
    
    IUnitroller public venusPool = 
        IUnitroller(address(0xfD36E2c2a6789Db23113685031d7F16329158384));

    IPool public aavePool = IPool(address(0x0b913A76beFF3887d35073b8e5530755D60F78C7));

    address public immutable WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address public immutable reward;
    address public immutable stakingPool;
    address public immutable invitationPool;

    mapping(address => uint256) public tokenAmounts;
    mapping(address => uint256) public aaveAmounts;
    mapping(address => address) public vTokens;

    event WethDeposited(uint256 amount);
    event WethWithdrawn(uint256 amount);
    event StakingRateUpdated(uint256 pre,uint256 newRate);
    event InvitationRateUpdated(uint256 pre,uint256 newRate);
    event InvitationPoolTransfered(address indexed token,uint256 amount);
    event StakingPoolTransfered(address indexed token,uint256 amount,uint256 duration);
    event BorrowedFromVenus(address indexed _vToken,uint256 amount);
    event RepaidToVenus(address indexed _vToken,uint256 amount);
    event BorrowedFromAave(address indexed _token,uint256 amount,uint256 interestRateMode,uint16 referralCode);
    event RepaidToAave(address indexed _token,uint256 amount,uint256 rateMode);
    event VenusPoolUpdated(address indexed pre,address indexed newPool);
    event AavePoolUpdated(address indexed pre,address indexed newPool);
    event RouterV2Updated(address indexed pre,address indexed newRouter,bool isUni);
    event RouterV3Updated(address indexed pre,address indexed newRouter,bool isUni);
    event PositionUpdated(address indexed pre,address indexed newPosition,bool isUni);
    event DepositedToVenus(address indexed from, address indexed to, address indexed token,uint256 amount);
    event WithdrawnFromVenus(address indexed from, address indexed to, address indexed token,uint256 amount);
    event DepositedToAave(address indexed from, address indexed to, address indexed token,uint256 amount);
    event WithdrawnFromAave(address indexed from, address indexed to, address indexed token,uint256 amount);
    event FeesCollected(address recipient, uint256 tokenId, uint256 amount0, uint256 amount1);
    event Withdrawn(address indexed from, address indexed to, address indexed token,uint256 amount);
    event Claimed(address indexed from, address indexed to,uint256 amount);
    event VTokenUpdated(address indexed token,address indexed vtoken);

    receive() external payable {}

    constructor(address _reward,address _stakingPool,address _invitationPool) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(EXECUTOR_ROLE, _msgSender());
        _grantRole(OPERATOR_ROLE, _msgSender());

        reward = _reward;
        stakingPool = _stakingPool;
        invitationPool = _invitationPool;
    }

    function setUniswapV2Router(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "New address is the zero address");
        emit RouterV2Updated(uniswapV2Router,_router,true);
        uniswapV2Router = _router;
    }

    function setPancakeV2Router(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "New address is the zero address");
        emit RouterV2Updated(pancakeV2Router,_router,false);
        pancakeV2Router = _router;
    }

    function setUniswapV3Router(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "New address is the zero address");
        emit RouterV2Updated(uniswapV3Router,_router,true);
        uniswapV3Router = _router;
    }

    function setPancakeV3Router(address _router) external onlyRole(OPERATOR_ROLE) {
        require(_router != address(0), "New address is the zero address");
        emit RouterV3Updated(pancakeV2Router,_router,false);
        pancakeV3Router = _router;
    }

    function setUniPositionManager(address _position) external onlyRole(OPERATOR_ROLE) {
        require(_position != address(0), "New address is the zero address");
        emit PositionUpdated(uniPositionManager,_position,true);
        uniPositionManager = _position;
    }

    function setPancakePositionManager(address _position) external onlyRole(OPERATOR_ROLE) {
        require(_position != address(0), "New address is the zero address");
        emit PositionUpdated(pancakePositionManager,_position,false);
        pancakePositionManager = _position;
    }

    function setVenusPool(address _pool) external onlyRole(OPERATOR_ROLE) {
        require(_pool != address(0), "New address is the zero address");
        emit VenusPoolUpdated(address(venusPool),_pool);
        venusPool = IUnitroller(_pool);
    }

    function setAavePool(address _pool) external onlyRole(OPERATOR_ROLE) {
        require(_pool != address(0), "New address is the zero address");
        emit AavePoolUpdated(address(aavePool),_pool);
        aavePool = IPool(_pool);
    }

    function setVTokens(address token,address vToken) external onlyRole(OPERATOR_ROLE) {
        emit VTokenUpdated(token,vToken);
        vTokens[token] = vToken;
    }

    function setStakingRate(uint256 newRate) external onlyRole(OPERATOR_ROLE) {
        emit StakingRateUpdated(stakingRate, newRate);
        stakingRate = newRate;
    }

    function setInvitationRate(uint256 newRate) external onlyRole(OPERATOR_ROLE) {
        emit InvitationRateUpdated(invitationRate, newRate);
        invitationRate = newRate;
    }

    function transfer(uint256 amount) external onlyRole(OPERATOR_ROLE) {
         require(
                invitationTransferred + amount <= 
                uint256(1e26).mul(invitationRate).div(DENOMINATOR),
                "exceeds the maximum value"
            );
        _executeTransfer(reward,invitationPool,amount);
        invitationTransferred = invitationTransferred.add(amount);
        emit InvitationPoolTransfered(invitationPool,amount);
    }

    function transfer(uint256 amount,uint256 duration) external onlyRole(OPERATOR_ROLE) {
        require(
            stakingTransferred + amount <= 
            uint256(1e26).mul(stakingRate).div(DENOMINATOR),
            "exceeds the maximum value"
        );
        _executeTransfer(reward,stakingPool,amount);
        stakingTransferred = stakingTransferred.add(amount);
        
        ILiquidityStaking(stakingPool).notifyRewardAmount(amount,duration);
        
        emit StakingPoolTransfered(stakingPool,amount,duration);
    }

    function wethDeposit(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        IWETH(WETH).deposit{value:amount}();
        emit WethDeposited(amount);
    }

    function wethWithdraw(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        IWETH(WETH).withdraw(amount);
        emit WethWithdrawn(amount);
    }

    function depositToAave(address token,uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(amount > 0,"not enough amount");
        
        _grantAllowance(token,address(aavePool),amount);

        if (token == address(0)) {
            IWETH(WETH).deposit{value: amount}();
            aavePool.supply(WETH, amount, address(this), 0);
        }else {
            aavePool.supply(token, amount, address(this), 0);
        }

        aaveAmounts[token] += amount;
        emit DepositedToAave(address(this), address(aavePool), token, amount);
    }

    function withdrawFromAave(address token,uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(aaveAmounts[token] >= amount,"aave not enough amount");
        
        if (token == address(0)) {
            aavePool.withdraw(WETH, amount, address(this));
            IWETH(WETH).withdraw(amount);
        }else {
            aavePool.withdraw(token, amount, address(this));
        }

        aaveAmounts[token] -= amount;
        emit WithdrawnFromAave(address(aavePool), address(this), token, amount);
    }

    function depositToVenus(address token,uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(amount > 0,"not enough amount");
        address vToken = vTokens[token];
        require(vToken != address(0),"invidate vtoken");

        if (token == address(0)) {
            IVBep20(vToken).mint{value:amount}();
        }else {
            _grantAllowance(token,vToken,amount);
            require(IVBep20(vToken).mint(amount) == 0, "Mint vToken failed");
        }

        address[] memory markets = new address[](1);
        markets[0] = address(vToken);
        uint[] memory enterMarketsErrors = venusPool.enterMarkets(markets);
        require(enterMarketsErrors[0] == 0, "Enter markets failed");

        tokenAmounts[token] += amount;

        emit DepositedToVenus(address(this), address(venusPool), token, amount);
    }

    function withdrawFromVenus(address token,uint256 amount) external onlyRole(OPERATOR_ROLE) {
        _withdrawFromVenus(token, amount);
    }

    function withdraw(address token,address to, uint256 amount) external onlyRole(EXECUTOR_ROLE) {
        require(amount > 0, "invidate amount");
        if (token == address(0) && address(this).balance < amount) {
            if (IERC20(WETH).balanceOf(address(this)) >= amount) {
                IWETH(WETH).withdraw(amount);
            }else {
                _withdrawFromVenus(token,amount);
            }
        }

        if (token != address(0) && IERC20(token).balanceOf(address(this)) < amount) {
            _withdrawFromVenus(token,amount);
        }

        _executeTransfer(token,to,amount);
        emit Withdrawn(_msgSender(), to, token, amount);
    }

    function claim(address to, uint256 amount) external onlyRole(EXECUTOR_ROLE) {
        _executeTransfer(reward,to,amount);
        emit Claimed(_msgSender(), to, amount);
    }

    function swapV3ExactTokensForTokens(
        address _inputToken, 
        address _outputToken, 
        uint256 _amountIn, 
        uint24 fee,
        uint256 deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 amountOut) {
        address router = isUni ? uniswapV3Router : pancakeV3Router;

        ISwapRouter.ExactInputSingleParams memory params = 
        ISwapRouter.ExactInputSingleParams({
            tokenIn: _inputToken,
            tokenOut: _outputToken,
            fee: fee,
            recipient: address(this),
            deadline: deadline,
            amountIn: _amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        TransferHelper.safeApprove(_inputToken, router, _amountIn);
        amountOut = ISwapRouter(router).exactInputSingle(params);
    }

    function swapV3AddLiquidity(
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) {
        address positionManager = isUni ? uniPositionManager : pancakePositionManager;

        TransferHelper.safeApprove(token0, positionManager, amount0);
        TransferHelper.safeApprove(token1, positionManager, amount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee, 
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: deadline
        });

        INonfungiblePositionManager(positionManager).mint(params);
    }

    function swapV3RemoveLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) {
        address positionManager = isUni ? uniPositionManager : pancakePositionManager;
        
        INonfungiblePositionManager.DecreaseLiquidityParams 
            memory params = INonfungiblePositionManager
                    .DecreaseLiquidityParams({
                        tokenId: tokenId,
                        liquidity: liquidity,
                        amount0Min: amount0Min,
                        amount1Min: amount1Min,
                        deadline: deadline
            });
            
        INonfungiblePositionManager(positionManager).decreaseLiquidity(params);

        _collectAllFees(tokenId,isUni);

        INonfungiblePositionManager(positionManager).burn(tokenId);
    }

    function collectAllFees(uint256 tokenId,bool isUni) 
        public onlyRole(OPERATOR_ROLE)
        returns (uint256 amount0, uint256 amount1) {
        return _collectAllFees(tokenId,isUni);
    }

    function swapV3IncreaseLiquidity(
        uint256 tokenId,
        address token0,
        address token1,
        uint256 amountAdd0,
        uint256 amountAdd1,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) {
        address positionManager = isUni ? uniPositionManager : pancakePositionManager;
        
        TransferHelper.safeApprove(token0, positionManager, amountAdd0);
        TransferHelper.safeApprove(token1, positionManager, amountAdd1);

        INonfungiblePositionManager.IncreaseLiquidityParams 
            memory params = INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amountAdd0,
                amount1Desired: amountAdd1,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            });

        INonfungiblePositionManager(positionManager).increaseLiquidity(params);
    }

    function swapV2ExactTokensForTokens(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        address[] calldata _path,
        uint256 _deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) {
        address router = isUni ? uniswapV2Router : pancakeV2Router;
        _grantAllowance(_tokenIn,router,_amountIn);

        ISwapV2Router(router).swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            _path,
            address(this),
            _deadline
        ); 
    }

    function swapV2AddLiquidity(
        address _tokenA,
        address _tokenB,
        uint256 _amountADesired,
        uint256 _amountBDesired,
        uint256 _amountAMin,
        uint256 _amountBMin,
        uint256 _deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) {        
        address router = isUni ? uniswapV2Router : pancakeV2Router;
        _grantAllowance(_tokenA,router,_amountADesired);
        _grantAllowance(_tokenB,router,_amountBDesired);

        ISwapV2Router(router).addLiquidity(
            _tokenA,
            _tokenB,
            _amountADesired,
            _amountBDesired,
            _amountAMin,
            _amountBMin,
            address(this),
            _deadline
        );
    }

    function swapV2RemoveLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        uint deadline,
        bool isUni
    ) external onlyRole(OPERATOR_ROLE) {  
        address router = isUni ? uniswapV2Router : pancakeV2Router;
        address lpToken = ISwapV2Factory(ISwapV2Router(router).factory()).getPair(tokenA, tokenB);

        _grantAllowance(lpToken,router,liquidity);

        ISwapV2Router(router).removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            address(this),
            deadline
        );
    }

    function borrowFromAave(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode
    ) external onlyRole(OPERATOR_ROLE) {
        bool isZero = asset == address(0);
        address token = isZero ? WETH : asset;

        aavePool.borrow(token, amount, interestRateMode, referralCode, address(this));

        if (isZero) {
            IWETH(WETH).withdraw(amount);
        }
        emit BorrowedFromAave(asset,amount,interestRateMode,referralCode);
    }

    function repayToAave(
        address asset,
        uint256 amount,
        uint256 rateMode
    ) external onlyRole(OPERATOR_ROLE) {
        bool isZero = asset == address(0);
        address token = isZero ? WETH : asset;

        if (isZero) {
            IWETH(WETH).deposit{value:amount}();
        }

        _grantAllowance(token, address(aavePool), amount);
        aavePool.repay(token, amount, rateMode, address(this));

        emit RepaidToAave(asset, amount, rateMode);
    }

    function borrowFromVenus(address _token, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        address vToken = vTokens[_token];
        require(vToken != address(0),"invidate vtoken");

        (, uint256 liquidity, ) = venusPool.getAccountLiquidity(address(this));
        require(amount <= liquidity, "Insufficient liquidity to borrow");
        
        require(IVBep20(vToken).borrow(amount) == 0, "borrow failed");
        emit BorrowedFromVenus(vToken,amount);
    }

    function repayToVenus(address _token, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        address vToken = vTokens[_token];
        require(vToken != address(0),"invidate vtoken");

        uint256 borrowBalance = IVBep20(vToken).borrowBalanceCurrent(address(this));
        require(borrowBalance > 0, "No outstanding debt");

        if (_token == address(0)) {
            require(address(this).balance >= borrowBalance, "Insufficient amount of native token to repay");
            IVBep20(vToken).repayBorrow{value: amount}();
        }else {
            _grantAllowance(_token, vToken, amount);
            IVBep20(vToken).repayBorrow(amount);
        }

        emit RepaidToVenus(vToken,amount);
    }

    function _collectAllFees(uint256 tokenId,bool isUni) private returns (uint256 amount0, uint256 amount1) {
        address positionManager = isUni ? uniPositionManager : pancakePositionManager;

        INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this), 
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0, amount1) = INonfungiblePositionManager(positionManager).collect(params);

        emit FeesCollected(address(this), tokenId, amount0, amount1);
    }

    function _withdrawFromVenus(address token,uint256 amount) private {
        require(tokenAmounts[token] >= amount,"venus not enough amount");
        address vToken = vTokens[token];
        require(vToken != address(0),"invidate vtoken");
        
        require(IVBep20(vToken).redeemUnderlying(amount) == 0, "Redeem underlying failed");
        tokenAmounts[token] -= amount;
        
        emit WithdrawnFromVenus(address(venusPool), address(this), token, amount);
    }

    function _executeTransfer(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _grantAllowance(
        address asset,
        address spender,
        uint256 amount
    ) private {
        IERC20(asset == address(0) ? WETH : asset).safeApprove(address(spender), amount);
    }
}