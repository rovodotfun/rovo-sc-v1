// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";
import {RovoTypes} from "./RovoTypes.sol";

contract HolderRewardDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant EPOCH_PUBLISHER_ROLE = keccak256("EPOCH_PUBLISHER_ROLE");
    address public splitter;
    IRovoRegistry public immutable registry;

    struct Pool { uint256 funded; uint256 reserved; uint256 claimed; }
    struct Epoch { bytes32 root; uint256 total; uint256 remaining; }

    mapping(address profileToken => Pool pool) public pools;
    mapping(address profileToken => mapping(uint256 epochId => Epoch epoch)) public epochs;
    mapping(address profileToken => mapping(uint256 epochId => mapping(address account => bool claimed))) public hasClaimed;

    error OnlySplitter();
    error SplitterAlreadySet();
    error InvalidCredit();
    error InsufficientUnreservedFunds();
    error InvalidProof();
    error NativeTransferFailed();

    event RewardsCredited(address indexed profileToken, address indexed asset, uint256 amount);
    event EpochPublished(address indexed profileToken, uint256 indexed epochId, bytes32 root, uint256 total);
    event RewardClaimed(address indexed profileToken, uint256 indexed epochId, address indexed account, uint256 amount);

    constructor(address admin, address publisher, address registry_) {
        registry = IRovoRegistry(registry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EPOCH_PUBLISHER_ROLE, publisher);
    }

    function setSplitter(address splitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (splitter != address(0) || splitter_ == address(0)) revert SplitterAlreadySet();
        splitter = splitter_;
    }

    function credit(address profileToken, address asset, uint256 amount) external payable {
        if (msg.sender != splitter) revert OnlySplitter();
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        Pool storage pool = pools[profileToken];
        if (asset != launch.pairToken || amount == 0) revert InvalidCredit();
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidCredit();
        } else if (msg.value != 0 || IERC20(asset).balanceOf(address(this)) < pool.funded - pool.claimed + amount) {
            revert InvalidCredit();
        }
        pool.funded += amount;
        emit RewardsCredited(profileToken, asset, amount);
    }

    function setEpochRoot(address profileToken, uint256 epochId, bytes32 root, uint256 total)
        external
        onlyRole(EPOCH_PUBLISHER_ROLE)
    {
        if (root == bytes32(0) || total == 0 || epochs[profileToken][epochId].root != bytes32(0)) revert InvalidProof();
        Pool storage pool = pools[profileToken];
        if (pool.funded - pool.claimed - pool.reserved < total) revert InsufficientUnreservedFunds();
        pool.reserved += total;
        epochs[profileToken][epochId] = Epoch(root, total, total);
        emit EpochPublished(profileToken, epochId, root, total);
    }

    function claim(address profileToken, uint256 epochId, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Epoch storage epoch = epochs[profileToken][epochId];
        if (hasClaimed[profileToken][epochId][msg.sender] || amount == 0 || amount > epoch.remaining) revert InvalidProof();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verifyCalldata(proof, epoch.root, leaf)) revert InvalidProof();
        hasClaimed[profileToken][epochId][msg.sender] = true;
        epoch.remaining -= amount;
        Pool storage pool = pools[profileToken];
        pool.reserved -= amount;
        pool.claimed += amount;
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        if (launch.pairToken == address(0)) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(launch.pairToken).safeTransfer(msg.sender, amount);
        }
        emit RewardClaimed(profileToken, epochId, msg.sender, amount);
    }
}
