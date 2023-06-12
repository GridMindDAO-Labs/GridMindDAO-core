// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Swap is Ownable,ReentrancyGuard,Pausable {
    using SafeERC20 for IERC20;

    address public router = 0x1111111254fb6c44bAC0beD2854e76F90643097d;

    event RouterUpdated(address indexed pre,address indexed newRouter);

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function setRouter(address newRouter) public onlyOwner {
        emit RouterUpdated(router,newRouter);
        router = newRouter;
    }

    function swap(address dstToken,uint256 amountIn,bytes calldata data) 
        external 
        nonReentrant 
        whenNotPaused
        payable 
        returns (uint256 returnAmount) {
        bool success;
        bytes memory returnData;

        if (dstToken == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            require(msg.value == amountIn,"invalidate amount");
            (success, returnData) = address(router).call{value:amountIn}(data);
        }else {
            IERC20(dstToken).safeTransferFrom(msg.sender, address(this), amountIn);
            
            IERC20(dstToken).safeApprove(address(router), amountIn);
            (success, returnData) = address(router).call(data);
        }

        if (success) {
            returnAmount = abi.decode(returnData, (uint256));
            require(returnAmount != 0,"swap error");
        }else {
            if (returnData.length < 68) {
                    revert("swap call error");
            } else {
                assembly {
                    returnData := add(returnData, 0x04)
                }
                revert(
                    abi.decode(returnData, (string))
                );
            }
        }
    }
}