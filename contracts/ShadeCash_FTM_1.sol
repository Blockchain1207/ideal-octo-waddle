/*
   ____  _               _       ____          _     
  / ___|| |__   __ _  __| | ___ / ___|__ _ ___| |__  
  \___ \| '_ \ / _` |/ _` |/ _ \ |   / _` / __| '_ \ 
   ___) | | | | (_| | (_| |  __/ |__| (_| \__ \ | | |
  |____/|_| |_|\__,_|\__,_|\___|\____\__,_|___/_| |_|

  Private transactions on the Fantom Opera
  https://shade.cash  

*/

// SPDX-License-Identifier: MIT

pragma solidity 0.5.17;

import "./ShadeCash.sol";

contract ShadeCash_FTM_1 is ShadeCash {
  constructor(
    IVerifier _verifier, 
    uint256 _denomination,
    uint32 _merkleTreeHeight,
    address payable _operator,
    address payable _taxRecipient,
    uint256 _taxPercent 
  ) ShadeCash(_verifier, _denomination, _merkleTreeHeight, _operator) public {
    denomination = _denomination; 
    taxPercent = _taxPercent; 
    totalAllocPoint = 1000;
    taxRecipients.push(Recipient({
      recipient: _taxRecipient,
      allocPoint: 1000        
    })); 
  }
    
  function _processDeposit() internal {
    require(msg.value == denomination, "ShadeCash_FTM_1 _processDeposit: Please send `mixDenomination` along with transaction");
  }

  function _processWithdraw(address payable _recipient, address payable _relayer, uint256 _fee, uint256 _refund) internal {
    require(msg.value == 0, "ShadeCash_FTM_1 _processWithdraw: Message value is supposed to be zero for FTM instance");
    require(_refund == 0, "ShadeCash_FTM_1 _processWithdraw: Refund value is supposed to be zero for FTM instance");
    
    uint256 amountToSend = denomination;
    uint256 tax;
    
    if (taxPercent > 0 && totalAllocPoint > 0) {
      tax = denomination.div(10000).mul(taxPercent);
      
      for (uint256 _index = 0; _index < taxRecipients.length; _index ++) {
        if (taxRecipients[_index].allocPoint > 0) { 
          uint256 amount = tax.mul(taxRecipients[_index].allocPoint).div(totalAllocPoint);        
          (bool taxSuccess, ) = taxRecipients[_index].recipient.call.value(amount)("");
          require(taxSuccess, "ShadeCash_FTM_1 _processWithdraw: Payment to tax recipient did not go thru");
        }
      } 
      amountToSend = amountToSend.sub(tax); 
    }  

    (bool recipientSuccess, ) = _recipient.call.value(amountToSend.sub(_fee))("");
    require(recipientSuccess, "ShadeCash_FTM_1 _processWithdraw: Payment to recipient did not go thru");
        
    if (_fee > 0) {
      (bool relayerSuccess, ) = _relayer.call.value(_fee)("");
      require(relayerSuccess, "ShadeCash_FTM_1 _processWithdraw: Payment to relayer did not go thru");
    }
  }
}
