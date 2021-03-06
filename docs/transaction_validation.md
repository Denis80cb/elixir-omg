# Transaction validation

NOTE:
* input = utxo

This document presents current way of stateless and stateful validation of 
`OMG.API.submit(encoded_signed_tx)` method.

#### Stateless validation

1. Decoding of encoded singed transaction using `OMG.API.State.Transaction.Signed.decode` method
    * Decoding using `ExRLP.decode` method and if fail then `{:error, :malformed_transaction_rlp}`
    * Checking signatures lengths and if fail then `{:error, :bad_signature_length}`
    * Checking addresses and if fail then `{:error, :malformed_address}` 
    * Checking if the integer fields contains integers
2. Checking signed_tx
    * if transaction have 2 empty inputs then `{:error, :no_inputs}`
    * if transaction have duplicated inputs then `{:error, :duplicate_inputs}`
    * if transaction have input and empty sig then  `{:error, :input_missing_for_signature}`
    * If transaction have no input and a sig then `{:error, :input_missing_for_signature}`
    * if transaction have no input and empty sig then `:ok`
3. Recovering of singed transaction using `OMG.API.State.Transaction.Recovered.recover_from`
    * Recovering address of spenders from signatures and if fail then `{:error, :signature_corrupt}`
4. Checking transaction fees using `OMG.API.FeeChecker.transaction_fees`
    * if the provided token is not allowed then `{:error, :token_not_allowed}`

#### Stateful validation

1. Validating block size
    * if the number of transactions in block exceeds limit then `{:error, :too_many_transactions_in_block}`
2. Checking correction of input positions
    * if the input is from the future block then `{:error, :input_utxo_ahead_of_state}`
    * if the input does not exists then `{:error, :utxo_not_found}`
    * if the owner of input does not match with spender then `{:error, :incorrect_spender}`
    * if the input currency is different from spent currency then `{:error, :incorrect_currency}`
3. Checking if the amounts from the provided inputs adds up. 
    * if not then `{:error, :amounts_dont_add_up}`
    
    
    
 


