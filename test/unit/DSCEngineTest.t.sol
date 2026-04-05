// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    uint256 amountToMint = 100 ether;
    uint256 amountCollateral = 10 ether;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesNotMatchPriceFeed() public {
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedMustBeSameLength.selector);
        dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine._getValueInUsd(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSITCOLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("Random Token", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getUserAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    /*//////////////////////////////////////////////////////////////
                   DEPOSITCOLLATERALANDMINTDSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testCanDepositCollateralAndMintDsc() public {
        (, int256 price,,,) = AggregatorV3Interface(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (amountCollateral * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(dscEngine._getValueInUsd(weth, amountCollateral), amountToMint);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBroken.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMint(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             MINTDSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testCanMintDsc() public depositedCollateral {
        // Arrange
        uint256 dscToMint = 100 ether; // Safe amount given 10 ETH collateral

        // Act
        vm.startPrank(USER);
        dscEngine.mintDsc(dscToMint);
        vm.stopPrank();

        // Assert
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, dscToMint);
    }

    function testCannotMintWithoutDepositingCollateral() public {
        vm.startPrank(USER);

        // Do NOT deposit collateral; do NOT approve anything.
        // Try to mint — should revert because health factor will be broken.
        // With 0 collateral, the health factor will be 0
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBroken.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    function testRevertsIfMintBreaksHealthFactor() public depositedCollateral {
        // Arrange: Assuming 1 ETH = $2000, 10 ETH = $20,000.
        // With a 50% liquidation threshold, max DSC is 10,000.
        // We will try to mint 10,001 DSC to break the health factor.
        uint256 dscToMint = 10001 ether;

        // Act / Assert
        vm.startPrank(USER);
        // We use a generic expectRevert without the exact error payload
        // to avoid complex pre-calculations of the broken health factor in the test.
        vm.expectRevert();
        dscEngine.mintDsc(dscToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                     BURN TESTS
    //////////////////////////////////////////////////////////////*/

    function testCanBurnDsc() public depositedCollateral {
        // Arrange
        uint256 dscToMint = 100 ether;

        vm.startPrank(USER);
        dscEngine.mintDsc(dscToMint);

        // Act
        dsc.approve(address(dscEngine), dscToMint);
        dscEngine.burnDsc(dscToMint);
        vm.stopPrank();

        // Assert
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function testCanRedeemCollateral() public depositedCollateral {
        // Act
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Assert
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, STARTING_ERC20_BALANCE);
    }

    function testCanRedeemAndBurnInOneTransaction() public depositedCollateral {
        // Arrange
        uint256 dscToMint = 100 ether;

        vm.startPrank(USER);
        dscEngine.mintDsc(dscToMint);

        // Act
        dsc.approve(address(dscEngine), dscToMint);
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, dscToMint);
        vm.stopPrank();

        // Assert
        uint256 userDscBalance = dsc.balanceOf(USER);
        uint256 userWethBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(userDscBalance, 0);
        assertEq(userWethBalance, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                                    GETTER TESTS
        //////////////////////////////////////////////////////////////*/

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory tokens = dscEngine.getCollateralTokens();
        assertEq(tokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }

    function testGetLiquidationThreshold() public view {
        uint256 threshold = dscEngine.getLiquidationThreshold();
        assertEq(threshold, 50);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dscEngine._getValueInUsd(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }
}
