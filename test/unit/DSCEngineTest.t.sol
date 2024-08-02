//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {console} from "forge-std/console.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
//import {MockFailedTransferFrom} from "../../test/mocks/MockFailedTransferFrom.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    DeployDSC deployer;
    DecentralisedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant COLLATERAL_COVER = 20 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DSC_TO_MINT = 1 ether;
    uint256 public constant LIQUIDATION_MINT = 8 ether;
    uint256 public constant MAX_BAL = 100 ether;
    uint256 public constant SMALL_COLLATERAL = 1 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_COVER);
    }

    //////////////////////////
    // Constructor Tests    //
    //////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedArraysMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////
    // Price Tests    //
    ////////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        //15e8 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 per eth, $100 of eth, therefore 0.05 eth
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////
    // depositCollateral Tests    //
    ////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateralAddress() public {
        ERC20Mock randomToken = new ERC20Mock();
        randomToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotSupported.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    //requires its own setup, cant use the default one in setUp()
    //this is correct and does test DSCEngine__TransferFailed, however there is a version mismatch
    // function testRevertsIfTransferFromFails() public {
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
    //     tokenAddresses = [address(mockDsc)];
    //     priceFeedAddresses = [ethUsdPriceFeed];
    //     vm.prank(owner);
    //     DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
    //     mockDsc.mint(USER, AMOUNT_COLLATERAL);

    //     vm.prank(owner);
    //     mockDsc.transferOwnership(address(mockEngine));
    //     //at this point it is running like normal

    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(mockEngine), AMOUNT_COLLATERAL);
    //     vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    //     mockEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    // }

    ////////////////////////////////
    // Minting Tests              //
    ////////////////////////////////

    function testMintSuccessful() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(DSC_TO_MINT);
        vm.stopPrank();
        (uint256 actualTotalDscMinted,) = engine.getAccountInformation(USER);
        assertEq(DSC_TO_MINT, actualTotalDscMinted);
    }

    function testMintRevertsOnBadHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint =
            ((uint256(price) * engine.getAdditionalFeedPrecision()) * AMOUNT_COLLATERAL) / engine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ////////////////////////////////
    // DepositAndMint Tests       //
    ////////////////////////////////

    function testSuccessfulDepositAndMintCall() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_TO_MINT);
        (uint256 actualTotalDscMinted, uint256 actualTotalCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 collateralValueInUsd =
            ((uint256(price) * engine.getAdditionalFeedPrecision()) * AMOUNT_COLLATERAL) / engine.getPrecision();
        assertEq(DSC_TO_MINT, actualTotalDscMinted);
        assertEq(collateralValueInUsd, actualTotalCollateralValueInUsd);
    }

    ////////////////////////////////
    // RedeemCollateral Tests     //
    ////////////////////////////////

    function testSuccessfullyRedeemedCollateral() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        (, uint256 collateralBeforeRedeem) = engine.getAccountInformation(USER);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, SMALL_COLLATERAL);
        vm.stopPrank();
        uint256 collatteralPriced =
            ((uint256(price) * engine.getAdditionalFeedPrecision()) * SMALL_COLLATERAL) / engine.getPrecision();
        (, uint256 collateralAfterRedeem) = engine.getAccountInformation(USER);
        assertEq(collateralBeforeRedeem - collatteralPriced, collateralAfterRedeem);
    }

    function testSuccessfullyRedeemedCollateralForDsc() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        vm.startPrank(USER);
        engine.mintDsc(DSC_TO_MINT);
        engine.mintDsc(DSC_TO_MINT);
        dsc.approve(address(engine), DSC_TO_MINT);
        engine.redeemCollateralForDsc(weth, DSC_TO_MINT, DSC_TO_MINT);
        vm.stopPrank();

        /**
         * initial collat = 10
         * initial mint = 0
         *
         * mint 1, mint 1 = 2 mint total
         * halfway through:
         * collat = 8
         * mint = 2
         *
         * end:
         * burn = 1
         * collat = 9
         * mint = 1
         */
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValueInUsd = (
            (uint256(price) * engine.getAdditionalFeedPrecision()) * (AMOUNT_COLLATERAL - DSC_TO_MINT)
                / engine.getPrecision()
        );

        assertEq(DSC_TO_MINT, totalDscMinted);
        assertEq(expectedCollateralValueInUsd, collateralValueInUsd);
    }

    function testMustRedeemMoreThanZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitsEvent() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, weth, SMALL_COLLATERAL);
        engine.redeemCollateral(weth, SMALL_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////////////
    // Liquidation Tests          //
    ////////////////////////////////

    //SHOULD MAKE A 'liquidated()' modifier
    function testSuccessfulLiquidation() public {
        //setup 2 users
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, LIQUIDATION_MINT);
        uint256 earlyHealthFactor = engine.getHealthFactor(USER);

        console.log("\nUSER: ----- earlyHealthFactor: ", earlyHealthFactor / 1e18);

        (uint256 userPreTotalDscMinted, uint256 userPreCollateralValueInUsd) = engine.getAccountInformation(USER);
        console.log("USER: ----- preTotalDscMinted: ", userPreTotalDscMinted / 1e18);
        console.log("USER: ----- preCollateralValueInUsd: ", userPreCollateralValueInUsd / 1e18);

        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 1e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_COVER); //20 eth to cover 10 eth
        engine.depositCollateralAndMintDsc(weth, COLLATERAL_COVER, LIQUIDATION_MINT);
        dsc.approve(address(engine), LIQUIDATION_MINT);
        uint256 preLiquidationHealthFactor = engine.getHealthFactor(USER);

        console.log("\nUSER: ----- preLiquidationHealthFactor: ", preLiquidationHealthFactor / 1e18);

        engine.liquidate(weth, USER, LIQUIDATION_MINT);
        vm.stopPrank();

        uint256 liquidatorBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedLiquidatorBalance = 8.8 ether; //8 ether LIQUIDATION_MINT + 0.8 ether from the 10% liquidation bonus in the contract
        assertEq(expectedLiquidatorBalance, liquidatorBalance);

        (uint256 userPostTotalDscMinted, uint256 userPostCollateralValueInUsd) = engine.getAccountInformation(USER);
        console.log("USER: ----- posttotalDscMinted: ", userPostTotalDscMinted / 1e18);
        console.log("USER: ----- postcollateralValueInUsd: ", userPostCollateralValueInUsd / 1e18);
    }

    function testCantLiquidateBecauseHealthFactorOk() public {
        //setup 2 users
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, LIQUIDATION_MINT);

        vm.stopPrank();

        //int256 ethUsdUpdatedPrice = 1e8;
        //MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_COVER); //20 eth to cover 10 eth
        engine.depositCollateralAndMintDsc(weth, COLLATERAL_COVER, LIQUIDATION_MINT);
        dsc.approve(address(engine), LIQUIDATION_MINT);

        //this should revert as we have commented out the price update which was making the health factor bad
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, LIQUIDATION_MINT);
        vm.stopPrank();
    }

    // this function tests DSCEngine__HealthFactorNotImproved() however using out of date mocks on wrong versions
    // function testMustImproveHealthFactorOnLiquidation() public {
    //     MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
    //     tokenAddresses = [weth];
    //     feedAddresses = [ethUsdPriceFeed];
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
    //     mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();

    //     uint256 badCollateralCover = 1 ether;
    //     uint256 smallMint = 0.0001 ether;

    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).approve(address(engine), badCollateralCover);
    //     engine.depositCollateralAndMintDsc(weth, badCollateralCover, smallMint);
    //     dsc.approve(address(engine), smallMint);

    //     int256 ethUsdUpdatedPrice = 1e8;
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

    //     //vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
    //     engine.liquidate(weth, USER, smallMint);
    //     vm.stopPrank();
    // }

    ////////////////////////////////
    // Getter Tests               //
    ////////////////////////////////

    function testGetAdditonalFeedPrecision() public view {
        uint256 expectedPrecision = 1e10;
        uint256 actualPrecision = engine.getAdditionalFeedPrecision();
        assertEq(expectedPrecision, actualPrecision);
    }

    function testGetPrecision() public view {
        uint256 expectedPrecision = 1e18;
        uint256 actualPrecision = engine.getPrecision();
        assertEq(expectedPrecision, actualPrecision);
    }
}
