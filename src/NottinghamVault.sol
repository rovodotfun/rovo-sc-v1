// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";
import {RovoTypes} from "./RovoTypes.sol";

contract NottinghamVault is AccessControl, EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant IDENTITY_SIGNER_ROLE = keccak256("IDENTITY_SIGNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "ClaimAttestation(uint64 xUserId,string handle,address recipient,address profileToken,uint256 nonce,uint256 deadline)"
    );
    uint256 public constant MAX_ATTESTATION_LIFETIME = 10 minutes;

    struct ClaimAttestation {
        uint64 xUserId;
        string handle;
        address recipient;
        address profileToken;
        uint256 nonce;
        uint256 deadline;
    }

    struct PendingClaim {
        address recipient;
        uint64 effectiveAt;
    }

    IRovoRegistry public immutable registry;
    address public splitter;
    uint64 public immutable claimDelay;
    mapping(address profileToken => uint256 amount) public pendingBalance;
    mapping(address profileToken => PendingClaim claim) public pendingClaims;
    mapping(bytes32 digest => bool used) public usedAttestations;
    mapping(bytes32 nonceKey => bool used) public usedNonces;

    error OnlySplitter();
    error SplitterAlreadySet();
    error InvalidCredit();
    error InvalidAttestation();
    error ClaimNotReady();

    event VaultCredited(address indexed profileToken, address indexed asset, uint256 amount);
    event ClaimInitiated(address indexed profileToken, address indexed recipient, uint64 effectiveAt);
    event ClaimFinalized(address indexed profileToken, address indexed recipient, uint256 amount);

    constructor(address admin, address signer, address registry_, uint64 claimDelay_)
        EIP712("Rovo Identity", "1")
    {
        registry = IRovoRegistry(registry_);
        claimDelay = claimDelay_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(IDENTITY_SIGNER_ROLE, signer);
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
        } else if (msg.value != 0 || IERC20(asset).balanceOf(address(this)) < pendingBalance[profileToken] + amount) {
            revert InvalidCredit();
        }
        pendingBalance[profileToken] += amount;
        emit VaultCredited(profileToken, asset, amount);
    }

    function initiateClaim(ClaimAttestation calldata attestation, bytes calldata signature) external whenNotPaused {
        if (
            attestation.deadline < block.timestamp || attestation.deadline > block.timestamp + MAX_ATTESTATION_LIFETIME
                || attestation.recipient == address(0)
        ) revert InvalidAttestation();
        RovoTypes.Launch memory launch = registry.getLaunch(attestation.profileToken);
        if (launch.claimed || launch.xUserId != attestation.xUserId || launch.handleHash != keccak256(bytes(attestation.handle))) {
            revert InvalidAttestation();
        }
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH,
                attestation.xUserId,
                keccak256(bytes(attestation.handle)),
                attestation.recipient,
                attestation.profileToken,
                attestation.nonce,
                attestation.deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        bytes32 nonceKey = keccak256(abi.encode(CLAIM_TYPEHASH, attestation.xUserId, attestation.nonce));
        if (
            usedAttestations[digest] || usedNonces[nonceKey]
                || !hasRole(IDENTITY_SIGNER_ROLE, ECDSA.recover(digest, signature))
        ) {
            revert InvalidAttestation();
        }
        usedAttestations[digest] = true;
        usedNonces[nonceKey] = true;
        uint64 effectiveAt = uint64(block.timestamp) + claimDelay;
        pendingClaims[attestation.profileToken] = PendingClaim(attestation.recipient, effectiveAt);
        emit ClaimInitiated(attestation.profileToken, attestation.recipient, effectiveAt);
    }

    function finalizeClaim(address profileToken) external whenNotPaused nonReentrant {
        PendingClaim memory claim = pendingClaims[profileToken];
        if (claim.recipient == address(0) || block.timestamp < claim.effectiveAt) revert ClaimNotReady();
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        uint256 amount = pendingBalance[profileToken];
        delete pendingClaims[profileToken];
        pendingBalance[profileToken] = 0;
        registry.markClaimed(profileToken, launch.xUserId, claim.recipient);
        if (amount != 0) {
            if (launch.pairToken == address(0)) {
                (bool success,) = claim.recipient.call{value: amount}("");
                if (!success) revert InvalidCredit();
            } else {
                IERC20(launch.pairToken).safeTransfer(claim.recipient, amount);
            }
        }
        emit ClaimFinalized(profileToken, claim.recipient, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
    receive() external payable {}
}
