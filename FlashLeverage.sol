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
import { ICreditDelegationToken } from "https://raw.githubusercontent.com/aave/protocol-v2/master/contracts/interfaces/ICreditDelegationToken.sol";
import { IProtocolDataProvider } from "https://raw.githubusercontent.com/aave/code-examples-protocol/main/V2/Credit%20Delegation/Interfaces.sol";

import { IUniswapV2Router02 } from "https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol";

contract FlashLoanLeverage is IFlashLoanReceiver {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    
    enum CallbackMethod {
        Open,
        Close
    }
    
    address internal constant AAVE_CONTRACT = 0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5;
    address internal constant AAVE_PROTOCOL_PROVIDER_CONTRACT = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    address internal constant ONE_INCH_ADDRESS = 0x111111125434b319222CdBf8C261674aDB56F3ae;
    
    uint public constant AAVE_INTEREST_MODE = 2;
    
    ILendingPoolAddressesProvider public override ADDRESSES_PROVIDER;
    ILendingPool public override LENDING_POOL;
    IProtocolDataProvider public AAVE_PROTOCOL_PROVIDER;
    
    constructor() public {
        ADDRESSES_PROVIDER = ILendingPoolAddressesProvider(AAVE_CONTRACT);
        LENDING_POOL = ILendingPool(ADDRESSES_PROVIDER.getLendingPool());
        AAVE_PROTOCOL_PROVIDER = IProtocolDataProvider(AAVE_PROTOCOL_PROVIDER_CONTRACT);
    }

    receive() external payable {
    }

    function closePosition(
        address inputToken,
        uint owingAmount,
        bytes calldata params
    ) internal {
        (, address sender, address leveragedToken, bytes memory oneInchTxData, uint withdrawAmount) = abi.decode(params, (CallbackMethod, address, address, bytes, uint));
        (address aToken,,) = AAVE_PROTOCOL_PROVIDER.getReserveTokensAddresses(leveragedToken);
        
        // Repay the debt using the FlashLoan
        
        uint repayAmount = IERC20(inputToken).balanceOf(address(this));
        IERC20(inputToken).approve(address(LENDING_POOL), repayAmount);
        LENDING_POOL.repay(inputToken, repayAmount, AAVE_INTEREST_MODE, sender);

        // Swap aToken for flashloaned token

        IERC20(aToken).safeTransferFrom(sender, address(this), withdrawAmount); // Get user aTokens

        IERC20(aToken).approve(address(ONE_INCH_ADDRESS), withdrawAmount);
        (bool swapSuccess, ) = ONE_INCH_ADDRESS.call(oneInchTxData); // Swap AWETH to DAI
        require(swapSuccess, "OneInch swap failed");
        
        require(IERC20(inputToken).balanceOf(address(this)) > 0, "got no DAI from oneInch");
            
        // TODO: fail if AAVE risk is too high
        
        require(IERC20(inputToken).balanceOf(address(this)) > owingAmount, "Not enough DAI to repay");
        
        // Return excess tokens to sender
        if(IERC20(inputToken).balanceOf(address(this)) > owingAmount) {
            IERC20(inputToken).transfer(sender, IERC20(inputToken).balanceOf(address(this)) - owingAmount);
        }
    }

    function openPosition(
        address inputToken,
        uint owingAmount,
        bytes calldata params
    ) internal {
        (, address sender, address leveragedToken, bytes memory oneInchTxData,) = abi.decode(params, (CallbackMethod, address, address, bytes, uint));
        (,,address debtToken) = AAVE_PROTOCOL_PROVIDER.getReserveTokensAddresses(inputToken);
        (address aToken,,) = AAVE_PROTOCOL_PROVIDER.getReserveTokensAddresses(leveragedToken);

        // oneInch swap user token and borrowed token for leveraging token
        
        IERC20(inputToken).approve(address(ONE_INCH_ADDRESS), IERC20(inputToken).balanceOf(address(this)));
        (bool swapSuccess, ) = ONE_INCH_ADDRESS.call(oneInchTxData);
        require(swapSuccess, "OneInch swap failed");
        require(IERC20(inputToken).balanceOf(address(this)) == 0, "Did not convert all DAI");
        require(IERC20(leveragedToken).balanceOf(address(this)) > 0, "oneInch did not return expected token");
    
        // Deposit leveraging token to AAVE on behalf of user
        
        IERC20(leveragedToken).approve(address(LENDING_POOL), IERC20(leveragedToken).balanceOf(address(this)));
        LENDING_POOL.deposit(leveragedToken, IERC20(leveragedToken).balanceOf(address(this)), sender, 0);
        require(IERC20(leveragedToken).balanceOf(address(this)) == 0, "AAVE didn't take all leveraging token");
        require(IERC20(aToken).balanceOf(sender) > 0, "Did not receive any A token from AAVE");
    
        // Borrow amountOwing DAI and repay the loan
    
        require(ICreditDelegationToken(debtToken).borrowAllowance(sender, address(this)) >= owingAmount, "Not enough allowance to borrow");
        LENDING_POOL.borrow(inputToken, owingAmount, AAVE_INTEREST_MODE, 0, sender);
    
        require(IERC20(inputToken).balanceOf(address(this)) >= owingAmount, "Not enough funds to repay");
    }

    // Convert the user funds and flashloan to ETH 
    // Deposit the ETH to AAVE 
    // Borrow the flashloan amount from AAVE 
    // Repay the flashloan 
    function executeOperation(
        address[] calldata assets,
        uint[] calldata amounts,
        uint[] calldata premiums,
        address initiator,
        bytes calldata params
    )
        external
        override
        returns (bool)
    {
        (CallbackMethod method,,,,) = abi.decode(params, (CallbackMethod, address, address, bytes, uint));

        uint owingAmount = amounts[0].add(premiums[0]);

        if(method == CallbackMethod.Open) {
            openPosition(assets[0], owingAmount, params);
        } else if (method == CallbackMethod.Close) {
            closePosition(assets[0], owingAmount, params);
        } else {
            revert("Wrong FlashLoan callback method");
        }

        IERC20(assets[0]).approve(address(LENDING_POOL), owingAmount);

        return true;
    }

    // inputToken is the user funds and debt token
    // leveragedToken is the aToken
    // amount is user funds
    // oneInchTxData should call a swap for amount x3 inputToken (user funds + flashloan) to leveragedToken
    // Ask for a flashloan of 2x the user amount
    function open(
        address inputToken,
        address leveragedToken,
        uint amount,
        bytes calldata oneInchTxData
    ) public {
        require(amount > 0, "amount must be greater than zero");

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amount);
        
        address receiverAddress = address(this);

        address[] memory assets = new address[](1);
        assets[0] = inputToken;

        uint[] memory amounts = new uint[](1);
        amounts[0] = amount.mul(2); // TODO: input for leverage multiplicator

        // 0 = no debt, 1 = stable, 2 = variable
        uint[] memory modes = new uint[](1);
        modes[0] = 0;

        address onBehalfOf = address(this);
        bytes memory params = abi.encode(CallbackMethod.Open, msg.sender, leveragedToken, oneInchTxData, 0);
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
    
    // inputToken is the debt token
    // leveragedToken is the aToken
    // repayAmount is how much debt will be repayed by a FlashLoan
    // withdrawAmount is how much aToken will be converted in order to repay the flashloan
    // withdrawAmount value should be higher than repayAmount to account for slippage
    // oneInchTxData should call a swap for withdrawAmount aToken to inputToken
    function close(
        address inputToken,
        address leveragedToken,
        uint repayAmount,
        uint withdrawAmount,
        bytes calldata oneInchTxData
    ) public {
        (,,address debtToken) = AAVE_PROTOCOL_PROVIDER.getReserveTokensAddresses(inputToken);
        require(IERC20(debtToken).balanceOf(msg.sender) > 0, "Must have debt");
        
        (address aToken,,) = AAVE_PROTOCOL_PROVIDER.getReserveTokensAddresses(leveragedToken);
        require(IERC20(aToken).balanceOf(msg.sender) > 0, "Must have collateral");
        
        address receiverAddress = address(this);
        
        address[] memory assets = new address[](1);
        assets[0] = inputToken;

        uint[] memory amounts = new uint[](1);
        amounts[0] = repayAmount;

        // 0 = no debt, 1 = stable, 2 = variable
        uint[] memory modes = new uint[](1);
        modes[0] = 0;

        address onBehalfOf = address(this);
        bytes memory params = abi.encode(CallbackMethod.Close, msg.sender, leveragedToken, oneInchTxData, withdrawAmount);
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
