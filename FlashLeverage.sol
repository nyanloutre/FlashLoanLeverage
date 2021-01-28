// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import { IERC20 } from "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v3.3.0/contracts/token/ERC20/IERC20.sol";
import { SafeMath } from "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v3.3.0/contracts/math/SafeMath.sol";
import { SafeERC20 } from "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v3.3.0/contracts/token/ERC20/SafeERC20.sol";

import { IFlashLoanReceiver } from "https://raw.githubusercontent.com/aave/protocol-v2/master/contracts/flashloan/interfaces/IFlashLoanReceiver.sol";
import { ILendingPoolAddressesProvider } from "https://raw.githubusercontent.com/aave/protocol-v2/master/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import { ILendingPool } from "https://raw.githubusercontent.com/aave/protocol-v2/master/contracts/interfaces/ILendingPool.sol";
import { IWETHGateway } from "https://raw.githubusercontent.com/aave/protocol-v2/ice/mainnet-deployment-03-12-2020/contracts/misc/interfaces/IWETHGateway.sol";
import { IAToken } from "https://raw.githubusercontent.com/aave/protocol-v2/ice/mainnet-deployment-03-12-2020/contracts/interfaces/IAToken.sol";

import { IUniswapV2Router02 } from "https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol";

contract FlashLoanArbitrageur is IFlashLoanReceiver {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    // Kovan adresses
    address internal constant DAI_CONTRACT = 0xFf795577d9AC8bD7D90Ee22b6C1703490b6512FD;
    address internal constant WETH_CONTRACT = 0xd0A1E359811322d97991E03f863a0C30C2cF029C;
    address internal constant AWETH_CONTRACT = 0x87b1f4cf9BD63f7BBD3eE1aD04E8F52540349347;
    address internal constant AAVE_CONTRACT = 0x88757f2f99175387aB4C6a4b3067c77A695b0349;
    address internal constant UNISWAP_ROUTER_ADDRESS = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant WETH_GATEWAY_ADDRESS = 0xf8aC10E65F2073460aAD5f28E1EABE807DC287CF;
    
    ILendingPoolAddressesProvider public override ADDRESSES_PROVIDER;
    ILendingPool public override LENDING_POOL;
    IWETHGateway public WETH_GATEWAY;

    IUniswapV2Router02 public UNISWAP_ROUTER;
    
    // constructor(ILendingPoolAddressesProvider provider) public {
    //     ADDRESSES_PROVIDER = provider;
    //     LENDING_POOL = ILendingPool(provider.getLendingPool());
    // }
    
    constructor() public {
        ADDRESSES_PROVIDER = ILendingPoolAddressesProvider(AAVE_CONTRACT);
        LENDING_POOL = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());
        WETH_GATEWAY = IWETHGateway(WETH_GATEWAY_ADDRESS);
        UNISWAP_ROUTER = IUniswapV2Router02(UNISWAP_ROUTER_ADDRESS);
    }

    receive() external payable {
    }

    function swapERC20ForETH(address token, uint256 amountIn, uint256 amountOutMin) internal returns (uint swapReturns) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = UNISWAP_ROUTER.WETH();
    
        uint deadline = block.timestamp + 15; // Pass this as argument
        
        IERC20(token).approve(address(UNISWAP_ROUTER), amountIn);
        
        swapReturns = UNISWAP_ROUTER.swapExactTokensForETH(amountIn, amountOutMin, path, address(this), deadline)[0];
        
        require(swapReturns > 0, "Uniswap didn't return anything");
    }

    // Convert the user funds and flashloan to ETH 
    // Deposit the ETH to AAVE 
    // Borrow the flashloan amount from AAVE 
    // Repay the flashloan 
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    )
        external
        override
        returns (bool)
    {
        require(assets[0] == DAI_CONTRACT, "AAVE didn't provide expected token");
        
        uint256 fundsTotal = IERC20(DAI_CONTRACT).balanceOf(address(this));
        
        // Convert fundsTotal DAI to ETH
        uint amountOutMin = 0; // Pass this as argument
        swapERC20ForETH(DAI_CONTRACT, fundsTotal, amountOutMin);

        // Deposit ETH to AAVE 
        
        require(address(this).balance > 0, "Uniswap did not return ETH");
        WETH_GATEWAY.depositETH{ value: address(this).balance }(address(this), 0);
        // LENDING_POOL.deposit(address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), address(this).balance, address(this), 0);
        
        // Do something with the aWETH
        require(IERC20(AWETH_CONTRACT).balanceOf(address(this)) > 0, "Didn't receive any a token");
        // require(IERC20(AWETH_CONTRACT).balanceOf(address(this)) != 0, "Didn't receive any a token");
        
        // Borrow amountOwing DAI and repay the loan
        
        uint amountOwing = amounts[0].add(premiums[0]);
        
        LENDING_POOL.borrow(DAI_CONTRACT, amountOwing, 2, 0, address(this));

        require(IERC20(DAI_CONTRACT).balanceOf(address(this)) >= amountOwing, "Not enough funds to repay");
        
        IERC20(assets[0]).approve(address(LENDING_POOL), amountOwing);

        return true;
    }

    // Amount is user funds (ex: $1k)
    // Ask for a flashloan of 2x the amount
    // function leverage(uint256 amount) public {
    function leverage() public {
        // IERC20(DAI_CONTRACT).transferFrom(msg.sender, address(this), amount); // Get user funds
        uint256 amount = IERC20(DAI_CONTRACT).balanceOf(address(this)); // Remove this
        
        require(amount > 0, "Put some DAI in the contract first");
        
        address receiverAddress = address(this);

        address[] memory assets = new address[](1);
        assets[0] = DAI_CONTRACT;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount.mul(2); // Maybe as input for leverage multiplicator

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        address onBehalfOf = address(this);
        bytes memory params = "";
        uint16 referralCode = 0;

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
    }
}
