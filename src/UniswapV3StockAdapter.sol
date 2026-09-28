// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Converts native ETH or WETH into an admin-approved Stock Token through one verified Uniswap V3 pool.
/// @dev `data` is intentionally ignored: price/tick controls come from the configured pool, not untrusted calldata.
contract UniswapV3StockAdapter is AccessControl {
    using SafeERC20 for IERC20;

    address public constant NATIVE = address(0);
    IUniswapV3SwapRouter02 public immutable swapRouter;
    IUniswapV3Factory public immutable factory;
    address public immutable weth;
    mapping(address stockToken => uint24 fee) public stockTokenFee;

    error InvalidAddress();
    error InvalidInput();
    error PairNotConfigured(address stockToken);
    error PoolUnavailable(address stockToken, uint24 fee);

    event StockTokenConfigured(address indexed stockToken, uint24 fee);

    constructor(address admin, address swapRouter_, address factory_, address weth_) {
        if (admin == address(0) || swapRouter_ == address(0) || factory_ == address(0) || weth_ == address(0)) revert InvalidAddress();
        swapRouter = IUniswapV3SwapRouter02(swapRouter_);
        factory = IUniswapV3Factory(factory_);
        weth = weth_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    receive() external payable {}

    function configureStockToken(address stockToken, uint24 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stockToken == address(0) || stockToken == weth || fee == 0) revert InvalidInput();
        if (factory.getPool(weth, stockToken, fee) == address(0)) revert PoolUnavailable(stockToken, fee);
        stockTokenFee[stockToken] = fee;
        emit StockTokenConfigured(stockToken, fee);
    }

    /// @notice RovoZapRouter-compatible exact-input adapter call.
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata
    ) external payable returns (uint256 amountOut) {
        uint24 fee = stockTokenFee[tokenOut];
        if (amountIn == 0 || recipient == address(0) || (tokenIn != NATIVE && tokenIn != weth)) revert InvalidInput();
        if (fee == 0) revert PairNotConfigured(tokenOut);
        if (factory.getPool(weth, tokenOut, fee) == address(0)) revert PoolUnavailable(tokenOut, fee);
        if (tokenIn == NATIVE) {
            if (msg.value != amountIn) revert InvalidInput();
        } else {
            if (msg.value != 0) revert InvalidInput();
            IERC20(weth).forceApprove(address(swapRouter), amountIn);
        }
        amountOut = swapRouter.exactInputSingle{value: msg.value}(IUniswapV3SwapRouter02.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        }));
        if (amountOut < minAmountOut) revert InvalidInput();
    }
}
