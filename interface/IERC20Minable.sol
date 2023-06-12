
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IERC20Minable {
    function mint(address account, uint256 amount) external;
    function decimals() external view returns (uint256);
}