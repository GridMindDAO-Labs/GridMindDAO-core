
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IERC20Burnable {
    function burnFrom(address account, uint256 amount) external;
}
