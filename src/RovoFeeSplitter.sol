// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";
import {IRovoBucket, ILaunchFeeCollector} from "./interfaces/IRovoModules.sol";
import {RovoTypes} from "./RovoTypes.sol";

contract RovoFeeSplitter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant SUNSET = 60 days;

    IRovoRegistry public immutable registry;
    IRovoBucket public immutable nottingham;
    IRovoBucket public immutable holderRewards;
    IRovoBucket public immutable reservoir;
    address public immutable treasury;

    mapping(address asset => mapping(address recipient => uint256 amount)) public pending;
    mapping(address asset => uint256 amount) public pendingTotal;

    error UnauthorizedCollector(address caller);
    error InvalidAsset(address asset);
    error InvalidAmount();
    error NativeTransferFailed();
    error UnauthorizedHarvester(address caller);
    error InvalidAdmin();
    error InvalidTreasury();

    event FeesDispersed(
        address indexed profileToken,
        address indexed asset,
        uint256 amount,
        uint256 platform,
        uint256 creatorOrVault,
        uint256 rover,
        uint256 holders
    );
    event RecipientCredited(address indexed recipient, address indexed asset, uint256 amount);
    event BatchHarvestFailed(address indexed profileToken, bytes reason);

    constructor(
        address admin_, address registry_, address nottingham_, address holderRewards_, address reservoir_, address treasury_
    ) {
        if (admin_ == address(0)) revert InvalidAdmin();
        if (treasury_ == address(0)) revert InvalidTreasury();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        registry = IRovoRegistry(registry_);
        nottingham = IRovoBucket(nottingham_);
        holderRewards = IRovoBucket(holderRewards_);
        reservoir = IRovoBucket(reservoir_);
        treasury = treasury_;
    }

    function harvest(address profileToken) external returns (uint256) {
        // The self-call is used only by admin-gated harvestBatch so one failing token
        // cannot revert the already completed harvests in the same batch.
        if (msg.sender != address(this) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedHarvester(msg.sender);
        }
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        return ILaunchFeeCollector(launch.feeCollector).collect();
    }

    function harvestBatch(address[] calldata profileTokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i; i < profileTokens.length; ++i) {
            try this.harvest(profileTokens[i]) {} catch (bytes memory reason) {
                emit BatchHarvestFailed(profileTokens[i], reason);
            }
        }
    }

    function disperse(address profileToken, address asset, uint256 amount) external payable nonReentrant {
        if (amount == 0) revert InvalidAmount();
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        if (msg.sender != launch.feeCollector) revert UnauthorizedCollector(msg.sender);
        if (asset != launch.pairToken) revert InvalidAsset(asset);
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
        } else if (msg.value != 0 || IERC20(asset).balanceOf(address(this)) < pendingTotal[asset] + amount) {
            revert InvalidAmount();
        }

        uint256 platform = (amount * 1_000) / BPS;
        uint256 holders;
        uint256 creatorOrVault;
        uint256 rover;

        if (launch.launchType == RovoTypes.LaunchType.SelfRove) {
            holders = (amount * 2_000) / BPS;
            uint256 creatorBucket = (amount * 7_000) / BPS;
            uint256 shared = launch.shareWithHolders
                ? (creatorBucket * launch.creatorToHoldersBps) / BPS
                : 0;
            creatorOrVault = creatorBucket - shared;
            holders += shared;
            _creditRecipient(asset, launch.creator, creatorOrVault);
        } else {
            rover = (amount * 1_500) / BPS;
            holders = (amount * 1_500) / BPS;
            uint256 creatorBucket = (amount * 6_000) / BPS;
            _creditRecipient(asset, launch.rover, rover);

            if (!launch.claimed && block.timestamp >= uint256(launch.launchedAt) + SUNSET) {
                uint256 sunsetHolders = creatorBucket / 2;
                holders += sunsetHolders;
                platform += creatorBucket - sunsetHolders;
            } else if (!launch.claimed) {
                creatorOrVault = creatorBucket;
                _fundBucket(nottingham, profileToken, asset, creatorBucket);
            } else {
                uint256 shared = launch.shareWithHolders
                    ? (creatorBucket * launch.creatorToHoldersBps) / BPS
                    : 0;
                creatorOrVault = creatorBucket - shared;
                holders += shared;
                _creditRecipient(asset, launch.creator, creatorOrVault);
            }
        }

        uint256 accounted = platform + creatorOrVault + rover + holders;
        holders += amount - accounted;
        _fundBucket(reservoir, profileToken, asset, platform);
        _fundBucket(holderRewards, profileToken, asset, holders);

        emit FeesDispersed(profileToken, asset, amount, platform, creatorOrVault, rover, holders);
    }

    function withdraw(address asset) external nonReentrant returns (uint256 amount) {
        amount = pending[asset][msg.sender];
        if (amount == 0) revert InvalidAmount();
        pending[asset][msg.sender] = 0;
        pendingTotal[asset] -= amount;
        if (asset == address(0)) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(asset).safeTransfer(msg.sender, amount);
        }
    }

    function _creditRecipient(address asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        pending[asset][recipient] += amount;
        pendingTotal[asset] += amount;
        emit RecipientCredited(recipient, asset, amount);
    }

    function _fundBucket(IRovoBucket bucket, address profileToken, address asset, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            bucket.credit{value: amount}(profileToken, asset, amount);
        } else {
            IERC20(asset).safeTransfer(address(bucket), amount);
            bucket.credit(profileToken, asset, amount);
        }
    }

    receive() external payable {}
}
