// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";
import {RovoTypes} from "./RovoTypes.sol";

contract PlatformFeeReservoir is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    address public splitter;
    IRovoRegistry public immutable registry;
    mapping(address asset => uint256 amount) public credited;

    error OnlySplitter();
    error SplitterAlreadySet();
    error InvalidCredit();
    error NativeTransferFailed();

    event PlatformFeesCredited(address indexed profileToken, address indexed asset, uint256 amount);
    event Released(address indexed asset, address indexed executor, uint256 amount);

    constructor(address admin, address registry_) {
        registry = IRovoRegistry(registry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setSplitter(address splitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (splitter != address(0) || splitter_ == address(0)) revert SplitterAlreadySet();
        splitter = splitter_;
    }

    function credit(address profileToken, address asset, uint256 amount) external payable {
        if (msg.sender != splitter) revert OnlySplitter();
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        if (asset != launch.pairToken || amount == 0) revert InvalidCredit();
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidCredit();
        } else if (msg.value != 0 || IERC20(asset).balanceOf(address(this)) < credited[asset] + amount) {
            revert InvalidCredit();
        }
        credited[asset] += amount;
        emit PlatformFeesCredited(profileToken, asset, amount);
    }

    function release(address asset, uint256 amount, address executor) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        credited[asset] -= amount;
        if (asset == address(0)) {
            (bool success,) = executor.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(asset).safeTransfer(executor, amount);
        }
        emit Released(asset, executor, amount);
    }
}
