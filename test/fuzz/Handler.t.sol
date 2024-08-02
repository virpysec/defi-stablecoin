//SPDX-License-Identifier: MIT

//Handler is going to narrow down the way we call the function
//e.g. only call redeemCollateral when there is collateral present

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralisedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    address USER = makeAddr("USER");

    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    constructor(DSCEngine _engine, DecentralisedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }

        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        engine.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;

        // console.log("\n----- mintDsc FUNCTION ----- MINTED: ", amount);
        // (uint256 totalDscMintedCheck, uint256 collateralValueInUsdCheck) = engine.getAccountInformation(USER);
        // console.log(" - totalDscMintedCheck: ", totalDscMintedCheck);
        // console.log(" - collateralValueInUsdCheck: ", collateralValueInUsdCheck);
        // console.log(" ---- END ----\n");
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = amountCollateral > MAX_DEPOSIT_SIZE ? MAX_DEPOSIT_SIZE : amountCollateral; // amountCollateral greater than max depo size true THEN max depo size, false THEN amountCollateral
        amountCollateral = amountCollateral <= 0 ? 1 : amountCollateral; // amountCollateral less than or equal to 0 true THEN 1, false THEN amountCollateral

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);

        // console.log("\n----- depositCollateral FUNCTION ----- DEPOSITED: ", amountCollateral);
        // (uint256 totalDscMintedCheck, uint256 collateralValueInUsdCheck) = engine.getAccountInformation(USER);
        // console.log(" - totalDscMintedCheck: ", totalDscMintedCheck);
        // console.log(" - collateralValueInUsdCheck: ", collateralValueInUsdCheck);
        // console.log(" ---- END ----\n");
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUserPerToken(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        /**
         * This section, is ensuring this invariant doesnt revert on bad health factor
         * It is getting the expected health factor before calling engine.redeemCollateral and returning if the health factor is going to be bad
         */
        (uint256 amountMinted, uint256 currentCollateral) = engine.getAccountInformation(msg.sender);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            amountMinted, (currentCollateral - (engine.getUsdValue(address(collateral), amountCollateral)))
        );
        // console.log("EXPECTED HEALTH FACTOR -=-===-=-==-= ", expectedHealthFactor);
        // console.log("MIN HEALTH FACTOR -=-===-=-==-==---= ", MIN_HEALTH_FACTOR);
        if (expectedHealthFactor <= MIN_HEALTH_FACTOR) {
            //console.log("WOULD HAVE BROKEN HEALTH FACTOR");
            return;
        }

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        // console.log("\n----- redeemCollateral FUNCTION ----- REDEEMED: ", amountCollateral);
        // (uint256 totalDscMintedCheck, uint256 collateralValueInUsdCheck) = engine.getAccountInformation(USER);
        // console.log(" - totalDscMintedCheck: ", totalDscMintedCheck);
        // console.log(" - collateralValueInUsdCheck: ", collateralValueInUsdCheck);
        // console.log("MAX COLLAT REDEEM :::::", maxCollateralToRedeem);
        // console.log(" ---- END ----\n");
    }

    //chose uint96 just to keep the number low for ease
    //this breaks the invariant test suite @audit
    // function updateCollateralPriceEth(uint96 newPrice) public {
    //     int256 newPriceInt = int256((uint256(newPrice)));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    //Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
