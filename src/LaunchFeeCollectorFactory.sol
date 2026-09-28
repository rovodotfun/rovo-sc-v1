// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LaunchFeeCollector} from "./LaunchFeeCollector.sol";

contract LaunchFeeCollectorFactory is AccessControl {
    bytes32 public constant WRAPPER_ROLE = keccak256("WRAPPER_ROLE");
    address public immutable implementation;

    event CollectorCreated(bytes32 indexed launchKey, address indexed collector, address indexed quoteToken);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        implementation = address(new LaunchFeeCollector());
    }

    function create(bytes32 launchKey, address quoteToken, address feeEscrow, address splitter)
        external
        onlyRole(WRAPPER_ROLE)
        returns (address collector)
    {
        bytes32 salt = keccak256(abi.encode(launchKey, msg.sender));
        collector = Clones.cloneDeterministic(implementation, salt);
        LaunchFeeCollector(payable(collector)).initialize(launchKey, quoteToken, feeEscrow, splitter, msg.sender);
        emit CollectorCreated(launchKey, collector, quoteToken);
    }

    function predict(bytes32 launchKey, address wrapper) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(launchKey, wrapper));
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }
}
