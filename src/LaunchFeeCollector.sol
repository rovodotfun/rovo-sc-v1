// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPonsFeeEscrow} from "./interfaces/IPonsV2.sol";
import {IRovoFeeSplitter} from "./interfaces/IRovoModules.sol";

interface IRovoTreasuryAuthority {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function treasury() external view returns (address);
}

contract LaunchFeeCollector {
    using SafeERC20 for IERC20;

    bytes32 public launchKey;
    address public profileToken;
    address public quoteToken;
    address public feeEscrow;
    address public splitter;
    address public wrapper;
    bool private _initialized;
    uint256 private _locked;

    error AlreadyInitialized();
    error NotWrapper();
    error AlreadyBound();
    error ProfileTokenNotBound();
    error ReentrantCall();
    error NothingCollected();
    error OnlySplitter();
    error OnlyAdmin();
    error NativeTransferFailed();

    event ProfileTokenBound(address indexed profileToken);
    event RevenueCollected(address indexed profileToken, address indexed asset, uint256 amount);
    event RevenueRoutedToTreasury(
        address indexed profileToken, address indexed asset, address indexed treasury, uint256 amount, address admin
    );

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    function initialize(bytes32 launchKey_, address quoteToken_, address feeEscrow_, address splitter_, address wrapper_)
        external
    {
        if (_initialized) revert AlreadyInitialized();
        if (feeEscrow_ == address(0) || splitter_ == address(0) || wrapper_ == address(0)) revert AlreadyInitialized();
        _initialized = true;
        _locked = 1;
        launchKey = launchKey_;
        quoteToken = quoteToken_;
        feeEscrow = feeEscrow_;
        splitter = splitter_;
        wrapper = wrapper_;
    }

    function bindProfileToken(address profileToken_) external {
        if (msg.sender != wrapper) revert NotWrapper();
        if (profileToken != address(0)) revert AlreadyBound();
        if (profileToken_ == address(0)) revert ProfileTokenNotBound();
        profileToken = profileToken_;
        emit ProfileTokenBound(profileToken_);
    }

    function collect() external nonReentrant returns (uint256 amount) {
        if (msg.sender != splitter) revert OnlySplitter();
        address token = profileToken;
        if (token == address(0)) revert ProfileTokenNotBound();
        amount = _claim();
        if (quoteToken == address(0)) {
            IRovoFeeSplitter(splitter).disperse{value: amount}(token, address(0), amount);
        } else {
            IERC20(quoteToken).safeTransfer(splitter, amount);
            IRovoFeeSplitter(splitter).disperse(token, quoteToken, amount);
        }
        emit RevenueCollected(token, quoteToken, amount);
    }

    /// @notice Admin-selected alternative to the automatic Rovo split. Funds go
    /// directly from this launch's collector to the configured treasury wallet.
    function collectToTreasury() external nonReentrant returns (uint256 amount) {
        IRovoTreasuryAuthority authority = IRovoTreasuryAuthority(splitter);
        if (!authority.hasRole(bytes32(0), msg.sender)) revert OnlyAdmin();
        address token = profileToken;
        if (token == address(0)) revert ProfileTokenNotBound();
        address recipient = authority.treasury();
        amount = _claim();
        if (quoteToken == address(0)) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(quoteToken).safeTransfer(recipient, amount);
        }
        emit RevenueCollected(token, quoteToken, amount);
        emit RevenueRoutedToTreasury(token, quoteToken, recipient, amount, msg.sender);
    }

    function _claim() private returns (uint256 amount) {
        if (quoteToken == address(0)) {
            uint256 beforeBalance = address(this).balance;
            IPonsFeeEscrow(feeEscrow).claim();
            amount = address(this).balance - beforeBalance;
        } else {
            IERC20 asset = IERC20(quoteToken);
            uint256 beforeBalance = asset.balanceOf(address(this));
            IPonsFeeEscrow(feeEscrow).claimToken(quoteToken);
            amount = asset.balanceOf(address(this)) - beforeBalance;
        }
        if (amount == 0) revert NothingCollected();
    }

    receive() external payable {}
}
