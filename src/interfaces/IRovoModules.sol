// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRovoFeeSplitter {
    function disperse(address profileToken, address asset, uint256 amount) external payable;
}

interface IRovoBucket {
    function credit(address profileToken, address asset, uint256 amount) external payable;
}

interface ILaunchFeeCollector {
    function bindProfileToken(address profileToken) external;
    function collect() external returns (uint256 amount);
}
