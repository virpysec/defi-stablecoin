//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Decentralised Stable Coin
 * @author Virpy
 * Collateral: Exogenous (ETH AND BTC)
 * Minting: Algorithmic
 * Relative Stablility: Pegged to USD
 *
 * This contract is meant to be governed by DSCEngine
 * This is the ERC20 Implementation of the stablecoin
 */
contract DecentralisedStableCoin is ERC20Burnable, Ownable {
    error DecentralisedStableCoin__BurnAmountLessThanOrEqualToZero();
    error DecentralisedStableCoin__BurnAmountExceedsBalance();
    error DecentralisedStableCoin__CannotMintToZeroAddress();
    error DecentralisedStableCoin__MintAmountLessThanOrEqualToZero();

    constructor() ERC20("DecentralisedStableCoin", "DSC") Ownable(address(msg.sender)) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralisedStableCoin__BurnAmountLessThanOrEqualToZero();
        }
        if (balance < _amount) {
            revert DecentralisedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //uses main erc20 burnable burn function
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralisedStableCoin__CannotMintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralisedStableCoin__MintAmountLessThanOrEqualToZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
