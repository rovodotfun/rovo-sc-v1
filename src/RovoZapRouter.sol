// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRovoRegistry} from "./interfaces/IRovoRegistry.sol";
import {RovoTypes} from "./RovoTypes.sol";

/// @notice The only Pons curve call used before graduation. Pons curves reject this call once graduated.
interface IPonsV2Curve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable;
}

/// @notice Allowlisted adapter boundary for input conversion and post-graduation V4 execution.
/// Adapters receive tokens from this router and MUST return the actual output amount.
interface IRovoSwapAdapter {
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata data
    ) external payable returns (uint256 amountOut);
}

interface IPonsV2FactoryState {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function createGraduatedPool(address token) external;
}

/// @notice Buys Rovo profile tokens without guessing Pons factory internals.
/// @dev Before graduation this calls the launch's immutable Pons curve directly. After Pons has
/// created its V4 pool, an admin may bind a reviewed V4 adapter for that exact profile token.
contract RovoZapRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);
    IRovoRegistry public immutable registry;
    mapping(address adapter => bool allowed) public allowedAdapters;
    mapping(address profileToken => address adapter) public v4Adapters;

    error DeadlineExpired();
    error InvalidAmount();
    error InvalidAdapter();
    error V4RouteUnavailable(address profileToken);
    error InsufficientOutput(uint256 actual, uint256 minimum);
    error UnexpectedNativeValue();
    error NativeTransferFailed();
    error WrongPonsPhase(uint8 expected, uint8 actual);

    event AdapterSet(address indexed adapter, bool allowed);
    event V4AdapterSet(address indexed profileToken, address indexed adapter);
    event ZapBought(address indexed buyer, address indexed profileToken, address indexed pairToken, uint256 pairIn, uint256 profileOut, bool v4);
    event GraduationRequested(address indexed caller, address indexed profileToken);

    constructor(address admin, address registry_) {
        if (admin == address(0) || registry_ == address(0)) revert InvalidAdapter();
        registry = IRovoRegistry(registry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    receive() external payable {}

    function setAdapter(address adapter, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert InvalidAdapter();
        allowedAdapters[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    /// @dev Set only after independently confirming Pons has moved this token to phase 2 (PoolCreated).
    function setV4Adapter(address profileToken, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        registry.getLaunch(profileToken);
        if (!allowedAdapters[adapter]) revert InvalidAdapter();
        v4Adapters[profileToken] = adapter;
        emit V4AdapterSet(profileToken, adapter);
    }

    /// @notice Swap an input asset into the launch pair token, then buy on the Pons curve.
    /// @dev `msg.sender` is always Pons' recipient so recipient-specific Pons snipe tax cannot be redirected.
    function buyCurve(
        address profileToken,
        address inputToken,
        uint256 amountIn,
        uint256 minPairOut,
        uint256 minProfileOut,
        uint256 deadline,
        address inputAdapter,
        bytes calldata inputAdapterData
    ) external payable nonReentrant returns (uint256 profileOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        _requirePhase(launch, profileToken, 0);
        uint256 pairIn = _acquirePair(launch.pairToken, inputToken, amountIn, minPairOut, inputAdapter, inputAdapterData);
        uint256 beforeBalance = IERC20(profileToken).balanceOf(msg.sender);
        uint256 pairBalanceBeforeBuy = _pairBalance(launch.pairToken) - pairIn;
        if (launch.pairToken == NATIVE) {
            IPonsV2Curve(launch.curve).buy{value: pairIn}(pairIn, minProfileOut, msg.sender);
        } else {
            IERC20(launch.pairToken).forceApprove(launch.curve, pairIn);
            IPonsV2Curve(launch.curve).buy(pairIn, minProfileOut, msg.sender);
            IERC20(launch.pairToken).forceApprove(launch.curve, 0);
        }
        profileOut = IERC20(profileToken).balanceOf(msg.sender) - beforeBalance;
        if (profileOut < minProfileOut) revert InsufficientOutput(profileOut, minProfileOut);
        _refundPair(launch.pairToken, pairBalanceBeforeBuy);
        emit ZapBought(msg.sender, profileToken, launch.pairToken, pairIn, profileOut, false);
    }

    /// @notice Executes a reviewed Uniswap V4 adapter after Pons graduation.
    function buyV4(
        address profileToken,
        address inputToken,
        uint256 amountIn,
        uint256 minPairOut,
        uint256 minProfileOut,
        uint256 deadline,
        address inputAdapter,
        bytes calldata inputAdapterData,
        bytes calldata v4AdapterData
    ) external payable nonReentrant returns (uint256 profileOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        _requirePhase(launch, profileToken, 2);
        address adapter = v4Adapters[profileToken];
        if (!allowedAdapters[adapter]) revert V4RouteUnavailable(profileToken);
        uint256 pairIn = _acquirePair(launch.pairToken, inputToken, amountIn, minPairOut, inputAdapter, inputAdapterData);
        uint256 beforeBalance = IERC20(profileToken).balanceOf(msg.sender);
        uint256 pairBalanceBeforeSwap = _pairBalance(launch.pairToken) - pairIn;
        uint256 reported;
        if (launch.pairToken == NATIVE) {
            reported = IRovoSwapAdapter(adapter).swapExactInput{value: pairIn}(
                launch.pairToken, profileToken, pairIn, minProfileOut, msg.sender, v4AdapterData
            );
        } else {
            IERC20(launch.pairToken).forceApprove(adapter, pairIn);
            reported = IRovoSwapAdapter(adapter).swapExactInput(
                launch.pairToken, profileToken, pairIn, minProfileOut, msg.sender, v4AdapterData
            );
            IERC20(launch.pairToken).forceApprove(adapter, 0);
        }
        profileOut = IERC20(profileToken).balanceOf(msg.sender) - beforeBalance;
        if (profileOut < minProfileOut || reported < minProfileOut) revert InsufficientOutput(profileOut, minProfileOut);
        _refundPair(launch.pairToken, pairBalanceBeforeSwap);
        emit ZapBought(msg.sender, profileToken, launch.pairToken, pairIn, profileOut, true);
    }

    /// @notice Permissionless recovery action for Pons' transient Swept phase.
    function completeGraduation(address profileToken) external nonReentrant {
        RovoTypes.Launch memory launch = registry.getLaunch(profileToken);
        _requirePhase(launch, profileToken, 1);
        IPonsV2FactoryState(launch.ponsFactory).createGraduatedPool(profileToken);
        emit GraduationRequested(msg.sender, profileToken);
    }

    function _acquirePair(
        address pairToken, address inputToken, uint256 amountIn, uint256 minPairOut, address adapter, bytes calldata adapterData
    ) private returns (uint256 pairOut) {
        if (amountIn == 0) revert InvalidAmount();
        uint256 beforeBalance = _pairBalance(pairToken) - (pairToken == NATIVE ? msg.value : 0);
        if (inputToken == pairToken) {
            if (pairToken == NATIVE) {
                if (msg.value != amountIn) revert UnexpectedNativeValue();
            } else {
                if (msg.value != 0) revert UnexpectedNativeValue();
                IERC20(pairToken).safeTransferFrom(msg.sender, address(this), amountIn);
            }
        } else {
            if (!allowedAdapters[adapter]) revert InvalidAdapter();
            if (inputToken == NATIVE) {
                if (msg.value != amountIn) revert UnexpectedNativeValue();
                IRovoSwapAdapter(adapter).swapExactInput{value: amountIn}(inputToken, pairToken, amountIn, minPairOut, address(this), adapterData);
            } else {
                if (msg.value != 0) revert UnexpectedNativeValue();
                IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amountIn);
                IERC20(inputToken).forceApprove(adapter, amountIn);
                IRovoSwapAdapter(adapter).swapExactInput(inputToken, pairToken, amountIn, minPairOut, address(this), adapterData);
            }
        }
        pairOut = _pairBalance(pairToken) - beforeBalance;
        if (pairOut < minPairOut) revert InsufficientOutput(pairOut, minPairOut);
    }

    function _pairBalance(address pairToken) private view returns (uint256) {
        return pairToken == NATIVE ? address(this).balance : IERC20(pairToken).balanceOf(address(this));
    }

    function _refundPair(address pairToken, uint256 balanceBefore) private {
        uint256 refund = _pairBalance(pairToken) - balanceBefore;
        if (refund == 0) return;
        if (pairToken == NATIVE) {
            (bool success,) = msg.sender.call{value: refund}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(pairToken).safeTransfer(msg.sender, refund);
        }
    }

    function _requirePhase(RovoTypes.Launch memory launch, address profileToken, uint8 expected) private view {
        uint8 actual = IPonsV2FactoryState(launch.ponsFactory).getLaunchedToken(profileToken).phase;
        if (actual != expected) revert WrongPonsPhase(expected, actual);
    }
}
