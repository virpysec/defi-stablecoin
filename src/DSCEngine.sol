//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralisedStableCoin} from "./DecentralisedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Virpy
 * The system is designed to be as mininmal as possible, and have the tokens maintain a $1 Peg
 * This stablecoins has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC
 *
 * Our DSC system should always be "overcollateralised". More collateral than DSC at all times
 *
 * @notice This contract is the core of the DSC system.
 * @notice It handles all the logic for mining and redeeming, as well as depositing and withdrawing collateral
 * @notice This contratc is VERY loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////////
    // ERRORS            //
    ///////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAndPriceFeedArraysMustBeSameLength();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////
    // TYPES             //
    ///////////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////
    // STATE VARIABLES   //
    ///////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    DecentralisedStableCoin private immutable i_dsc;

    ///////////////////////
    // EVENTS            //
    ///////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////////////
    // MODIFIERS         //
    ///////////////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        // Check if the token is allowed
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    ///////////////////////
    // FUNCTIONS         //
    ///////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAndPriceFeedArraysMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralisedStableCoin(dscAddress);
    }

    ////////////////////////////////
    // EXTERNAL FUNCTIONS         //
    ////////////////////////////////
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the token to deposit as collateral
     * @param amountDscToMint The amount of DSC to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI (checks, effects, interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the token to deposit as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral the amount of collateral to burn
     * @param amountDscToBurn the amount of DSC to burn
     * @notice this function burns DSC and redeems underlying collateral in one tx
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeem collateral already checks healthfactor
    }

    //in order to redeem collateral,
    //keep a good health factor
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of DSC to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // dont need to check if health factor is broken, as they are burning DSC
    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnDsc(msg.sender, msg.sender, amountToBurn);
        _revertIfHealthFactorIsBroken(msg.sender); //complete backup, may not be necessary
    }

    /**
     *
     * @param tokenCollateralAddress The erc20 collateral address to liquidate from the user
     * @param user The user to liquidate who broke the health factor
     * @param debtToCover The amount of DSC you to burn to improve the users healthfactor
     * @notice you can partially liquidate a user
     * @notice you will get a liquidation bonus for taking a users funds (incentive to liquidate unhealthy users)
     * @notice this function working assumes the protocol will be roughly 200% overcollateralised in order for this to work
     * @notice a known bug would be if the protocol were 100% or less collateralized, then we wouldnt be able to incentivize liquidators
     * For example. if the price of the collateral plummeted before anyone could be liquidated
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        //Bad user: $140 eth, $100 DSC -> bad health factor
        //debt to cover $100
        //$100 of DSC == ?? ETH
        //0.05 eth if eth is $2000

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);
        //and give them a 10% bonus
        //so we are giving the liquidator $110 of weth for $100 dsc
        //we should implement a feature to liquidate in the event the protocol is insolvent
        //and sweep extra amounts into a treasury

        // 0.05 * 0.1 = 0.005. getting 0.055 eth
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        //redeeming from the user who is being liquidated, to msg.sender who is initiating the liquidation (the liquidator)
        _redeemCollateral(user, msg.sender, tokenCollateralAddress, totalCollateralToRedeem);
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);
        console.log("Starting User Health Factor: %s", startingUserHealthFactor);
        console.log("Ending User Health Factor: %s", endingUserHealthFactor);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        //if this process ruins the liquidators health factor, should revert too
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /////////////////////////////////////////
    // PRIVATE & INTERNAL VIEW FUNCTIONS   //
    /////////////////////////////////////////

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     *
     * @dev low level internal function, do not call unless function calling it is checking for healthfactors being broken
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        //100-1000 (this will revert automatically, if they pull out more than they have)
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, they get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////
    // PUBLIC & EXTERNAL VIEW FUNCTIONS   //
    ////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through all the tokens, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of eth (token)
        //$/eth
        //$2000 /Eth. $1000 = 0.5eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUserPerToken(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
