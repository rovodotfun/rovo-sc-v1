// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPonsFactoryV2, IPonsLaunchAndBuyV2} from "./interfaces/IPonsV2.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";
import {ILaunchFeeCollector} from "./interfaces/IRovoModules.sol";
import {LaunchFeeCollectorFactory} from "./LaunchFeeCollectorFactory.sol";
import {RovoTypes} from "./RovoTypes.sol";

contract RovoFactoryWrapper is AccessControl, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public constant IDENTITY_SIGNER_ROLE = keccak256("IDENTITY_SIGNER_ROLE");
    bytes32 public constant SELF_ROVE_TYPEHASH = keccak256(
        "SelfRoveAttestation(uint64 xUserId,string handle,bytes32 metadataHash,address recipient,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SCOUT_TYPEHASH = keccak256(
        "ScoutProfileAttestation(uint64 xUserId,string handle,bytes32 metadataHash,uint256 nonce,uint256 deadline)"
    );
    uint16 public constant MIN_CREATOR_TAX_BPS = 100;
    uint16 public constant MAX_CREATOR_TAX_BPS = 500;
    uint256 public constant MAX_ATTESTATION_LIFETIME = 10 minutes;

    struct TokenMetadata {
        string name;
        string symbol;
        string logo;
        string description;
        IPonsFactoryV2.Socials socials;
        bytes32 salt;
    }

    struct SelfRoveAttestation {
        uint64 xUserId;
        string handle;
        bytes32 metadataHash;
        address recipient;
        uint256 nonce;
        uint256 deadline;
    }

    struct ScoutProfileAttestation {
        uint64 xUserId;
        string handle;
        bytes32 metadataHash;
        uint256 nonce;
        uint256 deadline;
    }

    struct OpeningBuy {
        uint256 quoteIn;
        uint256 minTokensOut;
        address recipient;
    }

    IPonsFactoryV2 public immutable pons;
    IPonsLaunchAndBuyV2 public immutable ponsLaunchAndBuy;
    IRovoRegistry public immutable registry;
    LaunchFeeCollectorFactory public immutable collectorFactory;
    address public immutable splitter;
    address public immutable ponsFeeEscrow;
    address public immutable ponsMemeHook;
    uint16 public immutable scoutCreatorTaxBps;
    mapping(bytes32 digest => bool used) public usedAttestations;
    mapping(bytes32 nonceKey => bool used) public usedNonces;

    error InvalidAttestation();
    error InvalidCreatorTax(uint16 bps);
    error PairTokenNotApproved(address pairToken);
    error PairTokenEconomicsInvalid(address pairToken);
    error WrapperNotAllowed();
    error LaunchFeeMismatch(uint256 expected, uint256 actual);
    error InvalidOpeningBuy();
    error RefundFailed();

    event RovoLaunchCreated(
        address indexed token,
        address indexed curve,
        address indexed collector,
        uint64 xUserId,
        RovoTypes.LaunchType launchType
    );
    event RovoOpeningBuy(address indexed token, address indexed buyer, uint256 quoteIn, uint256 tokensOut);

    constructor(
        address admin,
        address identitySigner,
        address pons_,
        address ponsLaunchAndBuy_,
        address registry_,
        address collectorFactory_,
        address splitter_,
        address ponsFeeEscrow_,
        address ponsMemeHook_,
        uint16 scoutCreatorTaxBps_
    ) EIP712("Rovo Identity", "1") {
        if (scoutCreatorTaxBps_ < MIN_CREATOR_TAX_BPS || scoutCreatorTaxBps_ > MAX_CREATOR_TAX_BPS) {
            revert InvalidCreatorTax(scoutCreatorTaxBps_);
        }
        pons = IPonsFactoryV2(pons_);
        ponsLaunchAndBuy = IPonsLaunchAndBuyV2(ponsLaunchAndBuy_);
        registry = IRovoRegistry(registry_);
        collectorFactory = LaunchFeeCollectorFactory(collectorFactory_);
        splitter = splitter_;
        ponsFeeEscrow = ponsFeeEscrow_;
        ponsMemeHook = ponsMemeHook_;
        scoutCreatorTaxBps = scoutCreatorTaxBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(IDENTITY_SIGNER_ROLE, identitySigner);
    }

    receive() external payable {}

    function launchSelfRove(
        TokenMetadata calldata metadata,
        uint32 launchConfigId,
        address pairToken,
        uint16 creatorTaxBps,
        SelfRoveAttestation calldata attestation,
        bytes calldata signature
    ) external payable nonReentrant returns (address token, address curve) {
        if (
            msg.sender != attestation.recipient || attestation.xUserId == 0
                || attestation.deadline < block.timestamp
                || attestation.deadline > block.timestamp + MAX_ATTESTATION_LIFETIME
        ) {
            revert InvalidAttestation();
        }
        if (creatorTaxBps < MIN_CREATOR_TAX_BPS || creatorTaxBps > MAX_CREATOR_TAX_BPS || creatorTaxBps > pons.maxCreatorTaxBps()) {
            revert InvalidCreatorTax(creatorTaxBps);
        }
        bytes32 metadataHash_ = hashMetadata(metadata);
        if (metadataHash_ != attestation.metadataHash) revert InvalidAttestation();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            SELF_ROVE_TYPEHASH,
            attestation.xUserId,
            keccak256(bytes(attestation.handle)),
            attestation.metadataHash,
            attestation.recipient,
            attestation.nonce,
            attestation.deadline
        )));
        _consume(digest, keccak256(abi.encode(SELF_ROVE_TYPEHASH, attestation.xUserId, attestation.nonce)), signature);
        return _launch(
            metadata,
            launchConfigId,
            pairToken,
            creatorTaxBps,
            attestation.xUserId,
            attestation.handle,
            address(0),
            attestation.recipient,
            RovoTypes.LaunchType.SelfRove,
            OpeningBuy(0, 0, address(0))
        );
    }

    function launchSelfRoveAndBuy(
        TokenMetadata calldata metadata,
        uint32 launchConfigId,
        address pairToken,
        uint16 creatorTaxBps,
        SelfRoveAttestation calldata attestation,
        bytes calldata signature,
        uint256 quoteIn,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, address curve) {
        if (quoteIn == 0 || minTokensOut == 0) revert InvalidOpeningBuy();
        if (
            msg.sender != attestation.recipient || attestation.xUserId == 0
                || attestation.deadline < block.timestamp
                || attestation.deadline > block.timestamp + MAX_ATTESTATION_LIFETIME
        ) revert InvalidAttestation();
        if (creatorTaxBps < MIN_CREATOR_TAX_BPS || creatorTaxBps > MAX_CREATOR_TAX_BPS || creatorTaxBps > pons.maxCreatorTaxBps()) {
            revert InvalidCreatorTax(creatorTaxBps);
        }
        bytes32 metadataHash_ = hashMetadata(metadata);
        if (metadataHash_ != attestation.metadataHash) revert InvalidAttestation();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            SELF_ROVE_TYPEHASH,
            attestation.xUserId,
            keccak256(bytes(attestation.handle)),
            attestation.metadataHash,
            attestation.recipient,
            attestation.nonce,
            attestation.deadline
        )));
        _consume(digest, keccak256(abi.encode(SELF_ROVE_TYPEHASH, attestation.xUserId, attestation.nonce)), signature);
        return _launch(
            metadata, launchConfigId, pairToken, creatorTaxBps, attestation.xUserId, attestation.handle,
            address(0), attestation.recipient, RovoTypes.LaunchType.SelfRove,
            OpeningBuy(quoteIn, minTokensOut, msg.sender)
        );
    }

    function launchScout(
        TokenMetadata calldata metadata,
        uint32 launchConfigId,
        address pairToken,
        ScoutProfileAttestation calldata attestation,
        bytes calldata signature
    ) external payable nonReentrant returns (address token, address curve) {
        if (
            attestation.xUserId == 0 || attestation.deadline < block.timestamp
                || attestation.deadline > block.timestamp + MAX_ATTESTATION_LIFETIME
                || hashMetadata(metadata) != attestation.metadataHash
        ) {
            revert InvalidAttestation();
        }
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            SCOUT_TYPEHASH,
            attestation.xUserId,
            keccak256(bytes(attestation.handle)),
            attestation.metadataHash,
            attestation.nonce,
            attestation.deadline
        )));
        _consume(digest, keccak256(abi.encode(SCOUT_TYPEHASH, attestation.xUserId, attestation.nonce)), signature);
        return _launch(
            metadata,
            launchConfigId,
            pairToken,
            scoutCreatorTaxBps,
            attestation.xUserId,
            attestation.handle,
            msg.sender,
            address(0),
            RovoTypes.LaunchType.Scout,
            OpeningBuy(0, 0, address(0))
        );
    }

    function launchScoutAndBuy(
        TokenMetadata calldata metadata,
        uint32 launchConfigId,
        address pairToken,
        ScoutProfileAttestation calldata attestation,
        bytes calldata signature,
        uint256 quoteIn,
        uint256 minTokensOut
    ) external payable nonReentrant returns (address token, address curve) {
        if (quoteIn == 0 || minTokensOut == 0) revert InvalidOpeningBuy();
        if (
            attestation.xUserId == 0 || attestation.deadline < block.timestamp
                || attestation.deadline > block.timestamp + MAX_ATTESTATION_LIFETIME
                || hashMetadata(metadata) != attestation.metadataHash
        ) revert InvalidAttestation();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            SCOUT_TYPEHASH,
            attestation.xUserId,
            keccak256(bytes(attestation.handle)),
            attestation.metadataHash,
            attestation.nonce,
            attestation.deadline
        )));
        _consume(digest, keccak256(abi.encode(SCOUT_TYPEHASH, attestation.xUserId, attestation.nonce)), signature);
        return _launch(
            metadata, launchConfigId, pairToken, scoutCreatorTaxBps, attestation.xUserId, attestation.handle,
            msg.sender, address(0), RovoTypes.LaunchType.Scout,
            OpeningBuy(quoteIn, minTokensOut, msg.sender)
        );
    }

    function hashMetadata(TokenMetadata calldata metadata) public pure returns (bytes32) {
        return keccak256(abi.encode(
            keccak256(bytes(metadata.name)),
            keccak256(bytes(metadata.symbol)),
            keccak256(bytes(metadata.logo)),
            keccak256(bytes(metadata.description)),
            keccak256(bytes(metadata.socials.twitter)),
            keccak256(bytes(metadata.socials.telegram)),
            keccak256(bytes(metadata.socials.discord)),
            keccak256(bytes(metadata.socials.website)),
            keccak256(bytes(metadata.socials.farcaster)),
            metadata.salt
        ));
    }

    function _launch(
        TokenMetadata calldata metadata,
        uint32 launchConfigId,
        address pairToken,
        uint16 creatorTaxBps,
        uint64 xUserId,
        string calldata handle,
        address rover,
        address creator,
        RovoTypes.LaunchType launchType,
        OpeningBuy memory openingBuy
    ) private returns (address token, address curve) {
        if (!pons.canLaunch(address(this))) revert WrapperNotAllowed();
        if (pairToken != address(0)) {
            if (!pons.approvedPairTokens(pairToken)) revert PairTokenNotApproved(pairToken);
            (uint256 phantomQuote, uint256 threshold,) = pons.pairTokenEconomics(pairToken);
            if (phantomQuote == 0 || threshold == 0) revert PairTokenEconomicsInvalid(pairToken);
        }
        uint256 fee = pons.launchFee();
        uint256 expectedValue = fee + (pairToken == address(0) ? openingBuy.quoteIn : 0);
        if (msg.value != expectedValue) revert LaunchFeeMismatch(expectedValue, msg.value);

        bytes32 expectedEconomics = pons.previewLaunchEconomics(launchConfigId, pairToken);
        bytes32 handleHash = keccak256(bytes(handle));
        bytes32 launchKey = keccak256(abi.encode(xUserId, handleHash, metadata.salt));
        address collector = collectorFactory.create(launchKey, pairToken, ponsFeeEscrow, splitter);

        IPonsFactoryV2.TokenParams memory params = IPonsFactoryV2.TokenParams({
            name: metadata.name,
            symbol: metadata.symbol,
            logo: metadata.logo,
            description: metadata.description,
            socials: metadata.socials,
            creatorFeeRecipient: collector,
            creatorTaxBps: creatorTaxBps,
            buybackEnabled: false,
            expectedEconomics: expectedEconomics,
            salt: metadata.salt
        });
        if (openingBuy.quoteIn == 0) {
            (token, curve) = pons.launchToken{value: fee}(params, launchConfigId, pairToken);
        } else {
            if (openingBuy.minTokensOut == 0 || openingBuy.recipient == address(0)) revert InvalidOpeningBuy();
            uint256 tokensOut;
            if (pairToken == address(0)) {
                uint256 previousBalance = address(this).balance - msg.value;
                (token, curve, tokensOut) = ponsLaunchAndBuy.launchAndBuy{value: expectedValue}(
                    params, launchConfigId, pairToken, openingBuy.quoteIn, openingBuy.minTokensOut,
                    openingBuy.recipient, new address[](0)
                );
                uint256 refund = address(this).balance - previousBalance;
                if (refund != 0) {
                    (bool sent,) = payable(msg.sender).call{value: refund}("");
                    if (!sent) revert RefundFailed();
                }
            } else {
                IERC20 quote = IERC20(pairToken);
                uint256 previousBalance = quote.balanceOf(address(this));
                quote.safeTransferFrom(msg.sender, address(this), openingBuy.quoteIn);
                quote.forceApprove(address(ponsLaunchAndBuy), openingBuy.quoteIn);
                (token, curve, tokensOut) = ponsLaunchAndBuy.launchAndBuy{value: fee}(
                    params, launchConfigId, pairToken, openingBuy.quoteIn, openingBuy.minTokensOut,
                    openingBuy.recipient, new address[](0)
                );
                quote.forceApprove(address(ponsLaunchAndBuy), 0);
                uint256 refund = quote.balanceOf(address(this)) - previousBalance;
                if (refund != 0) quote.safeTransfer(msg.sender, refund);
            }
            emit RovoOpeningBuy(token, openingBuy.recipient, openingBuy.quoteIn, tokensOut);
        }
        ILaunchFeeCollector(collector).bindProfileToken(token);

        registry.registerLaunch(RovoTypes.Launch({
            token: token,
            curve: curve,
            pairToken: pairToken,
            feeCollector: collector,
            ponsFactory: address(pons),
            ponsFeeEscrow: ponsFeeEscrow,
            ponsMemeHook: ponsMemeHook,
            handleHash: handleHash,
            expectedEconomics: expectedEconomics,
            xUserId: xUserId,
            rover: rover,
            creator: creator,
            launchedAt: uint64(block.timestamp),
            creatorTaxBps: creatorTaxBps,
            creatorToHoldersBps: 0,
            launchConfigId: launchConfigId,
            launchType: launchType,
            claimed: launchType == RovoTypes.LaunchType.SelfRove,
            shareWithHolders: false
        }));
        emit RovoLaunchCreated(token, curve, collector, xUserId, launchType);
    }

    function _consume(bytes32 digest, bytes32 nonceKey, bytes calldata signature) private {
        if (
            usedAttestations[digest] || usedNonces[nonceKey]
                || !hasRole(IDENTITY_SIGNER_ROLE, ECDSA.recover(digest, signature))
        ) {
            revert InvalidAttestation();
        }
        usedAttestations[digest] = true;
        usedNonces[nonceKey] = true;
    }
}
