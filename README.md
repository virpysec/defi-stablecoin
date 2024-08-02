# Defi Stablecoin based on Cyfrin Updraft course

1. Relative Stability: Anchored or Pegged to the US dollar 
   1. Chainlink price feed
   2. Set a function to exchange ETH and BTC for $
2. Stability Mechanism (minting): Algorithmic (Decentralised)
   1. People can only mint the stablecoin with enough collateral (coded in)
3. Collateral Type: Exogenous (Crypto)
   1. wETH (ERC20)
   2. wBTC (ERC20)

## Built with Foundry

- All usual foundry build and test commands
- Tested running on local anvil chain
  - Should function on the sepolia eth testnet with some .env variables
- Required libraries:
  - smartcontractkit/chainlink-brownie-contracts
  - foundry-rs/forge-std
  - openzeppelin/openzeppelin-contracts