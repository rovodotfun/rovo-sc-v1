// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RovoTypes} from "../RovoTypes.sol";

interface IRovoRegistry {
    function getLaunch(address token) external view returns (RovoTypes.Launch memory);
    function registerLaunch(RovoTypes.Launch calldata launch) external;
    function markClaimed(address token, uint64 xUserId, address creator) external;
}
