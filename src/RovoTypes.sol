// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RovoTypes {
    enum LaunchType {
        Scout,
        SelfRove
    }

    struct Launch {
        address token;
        address curve;
        address pairToken;
        address feeCollector;
        address ponsFactory;
        address ponsFeeEscrow;
        address ponsMemeHook;
        bytes32 handleHash;
        bytes32 expectedEconomics;
        uint64 xUserId;
        address rover;
        address creator;
        uint64 launchedAt;
        uint16 creatorTaxBps;
        uint16 creatorToHoldersBps;
        uint32 launchConfigId;
        LaunchType launchType;
        bool claimed;
        bool shareWithHolders;
    }
}
