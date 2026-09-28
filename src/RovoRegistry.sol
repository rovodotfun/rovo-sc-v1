// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RovoTypes} from "./RovoTypes.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";

contract RovoRegistry is AccessControl, IRovoRegistry {
    bytes32 public constant LAUNCHER_ROLE = keccak256("LAUNCHER_ROLE");
    bytes32 public constant CLAIM_FINALIZER_ROLE = keccak256("CLAIM_FINALIZER_ROLE");

    mapping(address token => RovoTypes.Launch launch) private _launches;
    mapping(bytes32 handleHash => address token) public handleToToken;
    mapping(uint64 xUserId => address token) public xUserIdToToken;

    error HandleTaken(bytes32 handleHash, address existingToken);
    error XUserIdTaken(uint64 xUserId, address existingToken);
    error LaunchAlreadyRegistered(address token);
    error LaunchNotFound(address token);
    error InvalidLaunch();
    error AlreadyClaimed(address token);
    error NotCreator(address caller);
    error InvalidShareBps(uint16 bps);

    event LaunchRegistered(address indexed token, uint64 indexed xUserId, bytes32 indexed handleHash, address collector);
    event CreatorClaimed(address indexed token, uint64 indexed xUserId, address indexed creator);
    event ShareWithHoldersUpdated(address indexed token, bool enabled, uint16 bps);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function getLaunch(address token) external view returns (RovoTypes.Launch memory launch) {
        launch = _launches[token];
        if (launch.token == address(0)) revert LaunchNotFound(token);
    }

    function registerLaunch(RovoTypes.Launch calldata launch) external onlyRole(LAUNCHER_ROLE) {
        if (
            launch.token == address(0) || launch.curve == address(0)
                || launch.feeCollector == address(0) || launch.xUserId == 0 || launch.handleHash == bytes32(0)
        ) revert InvalidLaunch();
        if (_launches[launch.token].token != address(0)) revert LaunchAlreadyRegistered(launch.token);

        address byHandle = handleToToken[launch.handleHash];
        if (byHandle != address(0)) revert HandleTaken(launch.handleHash, byHandle);
        address byId = xUserIdToToken[launch.xUserId];
        if (byId != address(0)) revert XUserIdTaken(launch.xUserId, byId);

        _launches[launch.token] = launch;
        handleToToken[launch.handleHash] = launch.token;
        xUserIdToToken[launch.xUserId] = launch.token;
        emit LaunchRegistered(launch.token, launch.xUserId, launch.handleHash, launch.feeCollector);
    }

    function markClaimed(address token, uint64 xUserId, address creator) external onlyRole(CLAIM_FINALIZER_ROLE) {
        RovoTypes.Launch storage launch = _launches[token];
        if (launch.token == address(0)) revert LaunchNotFound(token);
        if (launch.claimed) revert AlreadyClaimed(token);
        if (launch.xUserId != xUserId || creator == address(0)) revert InvalidLaunch();
        launch.claimed = true;
        launch.creator = creator;
        emit CreatorClaimed(token, xUserId, creator);
    }

    function setShareWithHolders(address token, bool enabled, uint16 bps) external {
        RovoTypes.Launch storage launch = _launches[token];
        if (launch.token == address(0)) revert LaunchNotFound(token);
        if (!launch.claimed || msg.sender != launch.creator) revert NotCreator(msg.sender);
        if (enabled && bps > 10_000) revert InvalidShareBps(bps);
        launch.shareWithHolders = enabled;
        launch.creatorToHoldersBps = enabled ? bps : 0;
        emit ShareWithHoldersUpdated(token, enabled, enabled ? bps : 0);
    }
}
