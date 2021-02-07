window.addEventListener('load', async () => {
  if (window.ethereum) {

    // Metamask setup

    window.web3 = new Web3(ethereum);
    await ethereum.enable();
    const accounts = await web3.eth.getAccounts();

    // ABI setup

    let IFlashLoanLeverage;
    await fetch('ABIs/IFlashLoanLeverage.json')
      .then(response => response.json())
      .then(IFlashLoanLeverageABI => IFlashLoanLeverage = IFlashLoanLeverageABI);

    let IERC20;
    await fetch('ABIs/IERC20.json')
      .then(response => response.json())
      .then(IERC20ABI => IERC20 = IERC20ABI);

    let IProtocolDataProvider;
    await fetch('ABIs/IProtocolDataProvider.json')
      .then(response => response.json())
      .then(IProtocolDataProviderABI => IProtocolDataProvider = IProtocolDataProviderABI);

    let IDebtToken;
    await fetch('ABIs/IDebtToken.json')
      .then(response => response.json())
      .then(IDebtTokenABI => IDebtToken = IDebtTokenABI);

    // DOM setup

    const leverageContract = document.getElementById("contract");
    const ERC20input = document.getElementById("ERC20input");
    const ERC20output = document.getElementById("ERC20output");
    const openAmount = document.getElementById("openAmount");
    const closeAmount = document.getElementById("closeAmount");
    const statusTable = document.getElementById("statusTable").tBodies[0];

    // Create supported token list

    const protocolDataProviderContract = new web3.eth.Contract(IProtocolDataProvider, "0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d");

    await protocolDataProviderContract.methods
      .getAllReservesTokens()
      .call()
      .then(result => {
        ERC20input.innerHTML = "";
        result.forEach(token => {
          const tokenOption = document.createElement('option');
          tokenOption.setAttribute("value", token[1]);
          if(token[0] === "DAI"){
            tokenOption.setAttribute("selected", "");
          }
          tokenOption.innerText = token[0];
          ERC20input.appendChild(tokenOption);
          const outputTokenOption = tokenOption.cloneNode(true);
          if(token[0] === "WETH"){
            outputTokenOption.setAttribute("selected", "");
          } else {
            outputTokenOption.removeAttribute("selected");
          }
          ERC20output.appendChild(outputTokenOption);
        });
      });

    // Helper function to add the balance of any ERC20 compliant token in the table

    function updateERC20(token) {
      const tokenContract = new web3.eth.Contract(IERC20, token);
      tokenContract.methods
        .balanceOf(accounts[0])
        .call()
        .then(balance => Promise.all([
            tokenContract.methods
              .decimals()
              .call()
              .then(decimals => balance/10**decimals),
            tokenContract.methods
              .symbol()
              .call()
          ]
        ))
        .then(returnValue => {
          const newRow = statusTable.insertRow();
          const token = newRow.insertCell(0);
          const amount = newRow.insertCell(1);
          token.innerText = returnValue[1];
          amount.innerText = returnValue[0];
        })
        .catch((e) => {
          throw Error(`Can't update amount: ${e.message}`)
        });
    }

    function updateSelectedTokens() {
      statusTable.innerHTML = "";
      updateERC20(ERC20input.value);
      protocolDataProviderContract.methods
        .getReserveTokensAddresses(ERC20input.value)
        .call()
        .then(tokenAddresses => updateERC20(tokenAddresses.variableDebtTokenAddress));
      updateERC20(ERC20output.value);
      protocolDataProviderContract.methods
        .getReserveTokensAddresses(ERC20output.value)
        .call()
        .then(tokenAddresses => updateERC20(tokenAddresses.aTokenAddress));
    }

    updateSelectedTokens()

    ERC20input.onchange = updateSelectedTokens;
    ERC20output.onchange = updateSelectedTokens;

    function ERC20toWei(token, amount) {
      const tokenContract = new web3.eth.Contract(IERC20, token);
      return tokenContract.methods
        .decimals()
        .call()
        .then(decimals => new web3.utils.BN(web3.utils.toWei(amount))
          .div(
            new web3.utils.BN('10')
              .pow(new web3.utils.BN('18').sub(new web3.utils.BN(decimals)))
            )
        )
    }
      
    document.getElementById('swap').onclick = () => {
      const fromTokenAddress = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"; //ETH
      const toTokenAddress = ERC20input.value; //Input token
      const amount = web3.utils.toWei('1', 'ether');
      const fromAddress = accounts[0];
      const slippage = 5;
      const disableEstimate = true;
      fetch(`https://api.1inch.exchange/v2.0/swap?fromTokenAddress=${fromTokenAddress}&toTokenAddress=${toTokenAddress}&amount=${amount}&fromAddress=${fromAddress}&slippage=${slippage}&disableEstimate=${disableEstimate}`)
        .then(response => response.json())
        .then(json => {
          delete json.tx.gasPrice;
          delete json.tx.gas;
          return web3.eth.sendTransaction(json.tx)
        })
        .then(updateSelectedTokens)
        .catch((e) => {
          throw Error(`Error swapping ETH for input token: ${e.message}`)
        })
    };

    document.getElementById('approve_token').onclick = () => {
      const tokenContract = new web3.eth.Contract(IERC20, ERC20input.value);
      ERC20toWei(ERC20input.value, openAmount.value)
        .then(weiValue => tokenContract.methods
          .approve(
            leverageContract.value,
            weiValue
          )
          .send({from: accounts[0]})
          .catch((e) => {
            throw Error(`Error approving DAI: ${e.message}`)
          })
        );
    };

    document.getElementById('approve_delegate').onclick = () =>
      protocolDataProviderContract.methods
        .getReserveTokensAddresses(ERC20input.value)
        .call()
        .then(tokenAddresses => ERC20toWei(ERC20input.value, openAmount.value)
          .then(weiValue => new web3.eth.Contract(
              IDebtToken,
              tokenAddresses.variableDebtTokenAddress
            ).methods
              .approveDelegation(
                leverageContract.value,
                weiValue
                  .mul(new web3.utils.BN('2'))
                  .mul(new web3.utils.BN('10009'))
                  .div(new web3.utils.BN('10000')) // TODO: get FlashLoan rate programatically
              )
              .send({from: accounts[0]})
            )
        )
        .catch((e) => {
          throw Error(`Error approving delegation: ${e.message}`)
        });

    document.getElementById('open_position').onclick = () => {
      const flashLoanLeverageContract = new web3.eth.Contract(IFlashLoanLeverage, leverageContract.value);
      const fromTokenAddress = ERC20input.value;
      const toTokenAddress = ERC20output.value;
      const fromAddress = leverageContract.value;
      const slippage = 5;
      const disableEstimate = true;
      ERC20toWei(
        ERC20input.value,
        openAmount.value
      )
        .then(weiValue => {
          const amount = weiValue.mul(new web3.utils.BN('3'));
          return fetch(`https://api.1inch.exchange/v2.0/swap?fromTokenAddress=${fromTokenAddress}&toTokenAddress=${toTokenAddress}&amount=${amount}&fromAddress=${fromAddress}&slippage=${slippage}&disableEstimate=${disableEstimate}`)
            .then(response => response.json())
            .then(oneInchTxData => flashLoanLeverageContract.methods
              .open(ERC20input.value, ERC20output.value, weiValue, oneInchTxData.tx.data)
              .send({from: accounts[0]})
              .then(updateSelectedTokens)
            )
        })
        .catch((e) => {
          throw Error(`Error during leverage call: ${e.message}`)
        });
    };

    document.getElementById('approve_atoken').onclick = () => {
      protocolDataProviderContract.methods
        .getReserveTokensAddresses(ERC20output.value)
        .call()
        .then(tokenAddresses => new web3.eth.Contract(IERC20, tokenAddresses.aTokenAddress))
        .then(tokenContract => ERC20toWei(ERC20output.value, closeAmount.value)
          .then(weiValue => tokenContract.methods
            .approve(
              leverageContract.value,
              weiValue
            )
            .send({from: accounts[0]})
            .catch((e) => {
              throw Error(`Error approving DAI: ${e.message}`)
            })
          )
        )
    };

    document.getElementById('close_position').onclick = () => {
      const flashLoanLeverageContract = new web3.eth.Contract(IFlashLoanLeverage, leverageContract.value);
      const toTokenAddress = ERC20input.value;
      const slippage = "5";
      const fromAddress = leverageContract.value;
      const disableEstimate = true;

      protocolDataProviderContract.methods
        .getReserveTokensAddresses(ERC20output.value)
        .call()
        .then(tokenAddresses => tokenAddresses.aTokenAddress)
        .then(aTokenAddress => ERC20toWei(aTokenAddress, closeAmount.value)
          .then(weiValue => fetch(`https://api.1inch.exchange/v2.0/swap?fromTokenAddress=${aTokenAddress}&toTokenAddress=${toTokenAddress}&amount=${weiValue}&fromAddress=${fromAddress}&slippage=${slippage}&disableEstimate=${disableEstimate}`)
            .then(response => response.json())
            // .then(oneInchTxData => {
            //   console.log(fromAddress);
            //   console.log(toTokenAddress);
            //   console.log(new web3.utils.BN(oneInchTxData.toTokenAmount)
            //       .mul(new web3.utils.BN('9991'))
            //       .div(new web3.utils.BN('10000')) // x 0.9991 (lend fees)
            //       .mul(new web3.utils.BN('100').sub(new web3.utils.BN(slippage)))
            //       .div(new web3.utils.BN('100')).toString());
            //   console.log(oneInchTxData.fromTokenAmount);
            //   console.log(oneInchTxData.tx.data);
            // })
            .then(oneInchTxData => flashLoanLeverageContract.methods
              .close(
                ERC20input.value,
                ERC20output.value,
                new web3.utils.BN(oneInchTxData.toTokenAmount)
                  .mul(new web3.utils.BN('9991'))
                  .div(new web3.utils.BN('10000')) // x 0.9991 (lend fees)
                  .mul(new web3.utils.BN('100').sub(new web3.utils.BN(slippage)))
                  .div(new web3.utils.BN('100')), // x (1 - slippage %) (worst case slippage)
                oneInchTxData.fromTokenAmount,
                oneInchTxData.tx.data
              )
              .send({from: accounts[0]})
              .then(updateSelectedTokens)
            )
          )
        )
        .catch((e) => {
          throw Error(`Error closing position: ${e.message}`)
        });
    };
  } else {
    console.log('No Metamask found');
  }
});
