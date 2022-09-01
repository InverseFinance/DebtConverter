// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "forge-std/Vm.sol";
import { ICToken } from "../interfaces/ICToken.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { IFeed } from "../interfaces/IFeed.sol";
import { DebtConverter } from "../DebtConverter.sol";
import { ComptrollerInterface } from "../interfaces/ComptrollerInterface.sol";

contract ContractTest is DSTest {
    Vm internal constant vm = Vm(HEVM_ADDRESS);

    //Tokens
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant anEth = 0x697b4acAa24430F254224eB794d2a85ba1Fa1FB8;
    address public constant anYfi = 0xde2af899040536884e062D3a334F2dD36F34b4a4;
    address public constant anBtc = 0x17786f3813E6bA35343211bd8Fe18EC4de14F28b;

    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant YFI = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;

    //Chainlink Feeds
    IFeed ethFeed = IFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    IFeed btcFeed = IFeed(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);
    IFeed yfiFeed = IFeed(0xA027702dbb89fbd58938e4324ac03B58d812b0E1);
    
    //Inverse
    address oracle = 0xE8929AFd47064EfD36A7fB51dA3F8C5eb40c4cb4;
    address treasury = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
    address gov = 0x926dF14a23BE491164dCF93f4c468A50ef659D5B;
    ComptrollerInterface comptroller = ComptrollerInterface(0x4dCf7407AE5C07f8681e1659f626E114A7667339);

    //EOAs
    address user = address(69);
    address user2 = address(1337);

    //Numbas
    uint initialIncreasePerYear = 0;
    uint anTokenAmount = 50 * 10**8;
    uint anBtcAmount = 50 * 10**8;
    uint dolaAmount = 2 * 10 ** 7 * 10**18;

    DebtConverter debtConverter;

    error TransferToAddressNotWhitelisted();
    error ConversionOccurredAfterGivenEpoch();
    error AlreadyRedeemedThisEpoch();
    error OnlyOwner();
    error OnlyGovernance();
    error InvalidDebtToken();
    error ConversionEpochNotEqualToCurrentEpoch(uint currentEpoch, uint repaymentEpoch);
    error ThatEpochIsInTheFuture();
    error ConversionHasNotBeenRedeemedBefore();
    
    function setUp() public {
        debtConverter = new DebtConverter(0, gov, treasury, gov, oracle);

        vm.startPrank(gov);
        gibDOLA(gov, dolaAmount);
        IERC20(DOLA).approve(address(debtConverter), type(uint256).max);
        comptroller._setTransferPaused(false);
        vm.stopPrank();
    }

    function testMaxConvertPriceIsRespectedWhenOraclePriceIsHigherBtc() public {
        vm.startPrank(gov);
        debtConverter.setMaxConvertPrice(anBtc, 10_000 * 1e18);
        comptroller._setMintPaused(anBtc, false);

        vm.stopPrank();
        vm.startPrank(user);

        gibToken(WBTC, user, 6e8);
        IERC20(WBTC).approve(anBtc, type(uint).max);
        ICToken(anBtc).mint(1e8);
        uint cTokenBal = ICToken(anBtc).balanceOf(user);
        ICToken(anBtc).mint(5e8);

        IERC20(anBtc).approve(address(debtConverter), type(uint).max);

        debtConverter.convert(anBtc, cTokenBal, 0);
        assertLe(debtConverter.outstandingDebt(), 10_000 * 1e18 * 1001/1000, "oustanding debt less than 10,000");
        assertGe(debtConverter.outstandingDebt() * 1001/1000, 10_000 * 1e18, "outsandingDebt greater than 10,000");
    }

    function testMaxConvertPriceIsNotRespectedWhenOraclePriceIsLowerBtc() public {
        vm.startPrank(gov);
        debtConverter.setMaxConvertPrice(anBtc, 30_000 * 1e18);
        comptroller._setMintPaused(anBtc, false);

        vm.stopPrank();
        vm.startPrank(user);

        gibToken(WBTC, user, 6e8);
        IERC20(WBTC).approve(anBtc, type(uint).max);
        ICToken(anBtc).mint(1e8);
        uint cTokenBal = ICToken(anBtc).balanceOf(user);
        ICToken(anBtc).mint(5e8);

        IERC20(anBtc).approve(address(debtConverter), type(uint).max);

        debtConverter.convert(anBtc, cTokenBal, 0);
        uint btcPrice = btcFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(btcPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted BTC worth more than amount of DOLA converted");
        assertLe(btcPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted BTC");
    }

    function testNoDifferenceInConversionWhenMaxConvertPriceIsZero() public {
        vm.startPrank(gov);
        comptroller._setMintPaused(anBtc, false);
        debtConverter.setMaxConvertPrice(anBtc, 10_000 * 1e18);
        debtConverter.setMaxConvertPrice(anBtc, 0);

        vm.stopPrank();
        vm.startPrank(user);

        gibToken(WBTC, user, 6e8);
        IERC20(WBTC).approve(anBtc, type(uint).max);
        ICToken(anBtc).mint(1e8);
        uint cTokenBal = ICToken(anBtc).balanceOf(user);
        ICToken(anBtc).mint(5e8);

        IERC20(anBtc).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anBtc, cTokenBal, 0);

        uint btcPrice = btcFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(btcPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted BTC worth more than amount of DOLA converted");
        assertLe(btcPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted BTC");
    }

    function testMaxConvertPriceIsNotRespectedWhenOraclePriceIsLowerEth() public {
        vm.startPrank(gov);
        debtConverter.setMaxConvertPrice(anEth, 3_000 * 1e18);
        comptroller._setMintPaused(anEth, false);

        vm.stopPrank();
        vm.startPrank(user);

        vm.deal(user, 6e18);
        IERC20(WBTC).approve(anEth, type(uint).max);
        ICToken(anEth).mint{value: 1 ether}();
        uint cTokenBal = ICToken(anEth).balanceOf(user);
        ICToken(anEth).mint{value: 5 ether}();

        IERC20(anEth).approve(address(debtConverter), type(uint).max);

        debtConverter.convert(anEth, cTokenBal, 0);
        uint ethPrice = ethFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(ethPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted ETH worth more than amount of DOLA converted");
        assertLe(ethPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted ETH");
    }

    function testMaxConvertPriceIsRespectedWhenOraclePriceIsHigherEth() public {
        vm.startPrank(gov);
        debtConverter.setMaxConvertPrice(anEth, 1_000 * 1e18);
        comptroller._setMintPaused(anEth, false);

        vm.stopPrank();
        vm.startPrank(user);

        vm.deal(user, 6e18);
        IERC20(WBTC).approve(anEth, type(uint).max);
        ICToken(anEth).mint{value: 1 ether}();
        uint cTokenBal = ICToken(anEth).balanceOf(user);
        ICToken(anEth).mint{value: 5 ether}();

        IERC20(anEth).approve(address(debtConverter), type(uint).max);

        debtConverter.convert(anEth, cTokenBal, 0);
        assertLe(debtConverter.outstandingDebt(), 1_000 * 1e18 * 1001/1000, "oustanding debt less than 1,000");
        assertGe(debtConverter.outstandingDebt() * 1001/1000, 1_000 * 1e18, "outsandingDebt greater than 1,000");
    }

    function testNoDifferenceInConversionWhenMaxConvertPriceIsZeroEth() public {
        vm.startPrank(gov);
        comptroller._setMintPaused(anEth, false);
        debtConverter.setMaxConvertPrice(anEth, 10_000 * 1e18);
        debtConverter.setMaxConvertPrice(anEth, 0);

        vm.stopPrank();
        vm.startPrank(user);

        vm.deal(user, 6e18);
        IERC20(WBTC).approve(anEth, type(uint).max);
        ICToken(anEth).mint{value: 1 ether}();
        uint cTokenBal = ICToken(anEth).balanceOf(user);
        ICToken(anEth).mint{value: 5 ether}();

        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, cTokenBal, 0);

        uint ethPrice = ethFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(ethPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted ETH worth more than amount of DOLA converted");
        assertLe(ethPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted ETH");
    }

    function testMintUsingEth() public {
        vm.startPrank(gov);
        comptroller._setMintPaused(anEth, false);

        vm.stopPrank();
        vm.startPrank(user);
        vm.deal(user, 6e18);

        ICToken(anEth).mint{value: 1e18}();
        uint cTokenBal = ICToken(anEth).balanceOf(user);
        ICToken(anEth).mint{value: 5e18}();

        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, cTokenBal, 0);

        uint ethPrice = ethFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(ethPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted ETH worth more than amount of DOLA converted");
        assertLe(ethPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted ETH");
    }

    function testMintUsingBTC() public {
        vm.startPrank(gov);
        comptroller._setMintPaused(anBtc, false);

        vm.stopPrank();
        vm.startPrank(user);

        gibToken(WBTC, user, 6e8);
        IERC20(WBTC).approve(anBtc, type(uint).max);
        ICToken(anBtc).mint(1e8);
        uint cTokenBal = ICToken(anBtc).balanceOf(user);
        ICToken(anBtc).mint(5e8);

        IERC20(anBtc).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anBtc, cTokenBal, 0);

        uint btcPrice = btcFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(btcPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted BTC worth more than amount of DOLA converted");
        assertLe(btcPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted BTC");
    }

    function testMintUsingYFI() public {
        vm.startPrank(gov);
        comptroller._setMintPaused(anYfi, false);

        vm.stopPrank();
        vm.startPrank(user);

        gibToken(YFI, user, 6e18);
        IERC20(YFI).approve(anYfi, type(uint).max);
        ICToken(anYfi).mint(1e18);
        uint cTokenBal = ICToken(anYfi).balanceOf(user);
        ICToken(anYfi).mint(5e18);

        IERC20(anYfi).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anYfi, cTokenBal, 0);

        uint yfiPrice = yfiFeed.latestAnswer();
        (,uint dolaConverted,) = debtConverter.conversions(user, 0);
        assertGe(yfiPrice * 1001/1000, convertDolaIOUsToDola(dolaConverted) / 1e10, "Converted YFI worth more than amount of DOLA converted");
        assertLe(yfiPrice, convertDolaIOUsToDola(dolaConverted) * 1001/1000 / 1e10, "Amount of DOLA converted worth more than converted YFI");
    }

    function testConvertBTC() public {
        convert(anBtc, anBtcAmount);
    }

    function testConvertYFI() public {
        convert(anYfi, anTokenAmount);
    }

    function testConvertETH() public {
        convert(anEth, anTokenAmount);
    }

    function testConvertFailsWithFakeAnToken() public {
        vm.expectRevert(InvalidDebtToken.selector);
        debtConverter.convert(address(1), anTokenAmount, 0);
    }

    function convert(address anToken, uint amount) public {
        gibAnTokens(user, anToken, amount);

        vm.startPrank(user);

        IERC20(anToken).approve(address(debtConverter), amount);
        uint underlyingAmount = ICToken(anToken).balanceOfUnderlying(user);
        debtConverter.convert(anToken, amount, 0);

        IFeed feed;
        if (anToken == anEth) {
            feed = ethFeed;
        } else if (anToken == anYfi) {
            feed = yfiFeed;
        } else if (anToken == anBtc) {
            feed = btcFeed;
        }

        uint decimals = 8;
        uint dolaToBeReceived = underlyingAmount * feed.latestAnswer();
        if (anToken == anBtc) {
            dolaToBeReceived = dolaToBeReceived * 10**2;
        } else {
            dolaToBeReceived = dolaToBeReceived / 10**decimals;
        }
        uint dolaIOUsReceived = debtConverter.balanceOf(user);
        uint dolaReceived = debtConverter.convertDolaIOUsToDola(dolaIOUsReceived);
        assertEq(dolaReceived, dolaToBeReceived, "dolaReceived not equal dolaToBeReceived");
    }

    function testRedeemWithInsufficientDolaIOUs() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs & whitelist gov address for transfers for testing purposes
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.whitelistTransferFor(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //transfer DOLA IOUs to gov. given 50e18 anTokenAmount, this will leave user with ~160 DOLA worth of IOUs
        //  with ~200 DOLA being claimable. Intended behavior is to redeem all remaining IOUs
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.transfer(gov, ethFeed.latestAnswer() * 99/100 * 1e10);
        uint dolaRedeemable = debtConverter.balanceOfDola(user);
        debtConverter.redeemConversion(0, 0);

        uint dolaRedeemed = IERC20(DOLA).balanceOf(user);

        assertEq(debtConverter.balanceOf(user), 0, "debtConverter balance not 0");
        assertEq(dolaRedeemable, dolaRedeemed, "dolaRedeemable not equal dolaRedeemed");
    }

    function testLargeRepaymentAndRedeemConversion() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount * 10000);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount * 10000);
        debtConverter.convert(anEth, anTokenAmount * 10000, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        gibDOLA(gov, 1_000_000_000e18);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(100_000e18);

        //Redeem DOLA IOUs on user
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemAll(0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }

    function testLargeRepaymentAndRedeemAll() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount * 10000);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount * 10000);
        debtConverter.convert(anEth, anTokenAmount * 10000, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        gibDOLA(gov, 1_000_000_000e18);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(100_000e18);

        //Redeem DOLA IOUs on user
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemAll(0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }

    function testSmallRepaymentAndRedeemConversion() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount * 10000);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount * 10000);
        debtConverter.convert(anEth, 1, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        gibDOLA(gov, 1_000_000_000e18);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //Redeem DOLA IOUs on user
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversionDust(0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);
        
        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }


    function testRedeemConversionDustFailsIfConversionNotUpToDate() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(ConversionEpochNotEqualToCurrentEpoch.selector, 0, 1));
        debtConverter.redeemConversionDust(0);
    }

    function testRedeemConversionDustFailsIfConversionHasNotBeenRedeemedBefore() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user2, anEth, anTokenAmount);

        vm.startPrank(user2);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.stopPrank();
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(ConversionHasNotBeenRedeemedBefore.selector));
        debtConverter.redeemConversionDust(0);
    }

    function testRedeemConversionDustFailsIf2PercentOfConversionUnclaimed() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt() * 98e18/100e18);

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        (,uint dolaIOUsConverted, uint dolaIOUsRedeemed) = debtConverter.conversions(user, 0);
        uint dolaIOUsLeftToRedeem = dolaIOUsConverted - dolaIOUsRedeemed;
        uint redeemablePct = dolaIOUsLeftToRedeem * 1e18 / dolaIOUsRedeemed;

        //Ensure that more than 1.2% of the conversion is left to redeem
        //This means that the call to `redeemConversionDust()` should transfer 0 DOLA
        assertGt(redeemablePct, .012e18, "More than 1.2% of conversion is left to redeem");

        uint userBalPrev = IERC20(DOLA).balanceOf(user);
        debtConverter.redeemConversionDust(0);

        assertEq(userBalPrev, IERC20(DOLA).balanceOf(user), "User previous balance not equal end balance");
    }

    function testRepaymentAndRedeemConversionWithDoubleRedemptions() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        uint dolaBalance = IERC20(DOLA).balanceOf(user);
        uint dolaIOUBalance = IERC20(address(debtConverter)).balanceOf(user); 
        debtConverter.redeemConversion(0, 0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        assertEq(IERC20(DOLA).balanceOf(user), dolaBalance, "Dola balance changed after second redemption");
        assertEq(IERC20(address(debtConverter)).balanceOf(user), dolaIOUBalance, "Dola IOU balance changed after second redemption");
        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }

    function testRepaymentAndRedeemConversionWithInterest() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        vm.warp(block.timestamp + (86400 * 365));
        debtConverter.accrueInterest();
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        uint dolaBalance = IERC20(DOLA).balanceOf(user);
        uint dolaIOUBalance = IERC20(address(debtConverter)).balanceOf(user); 
        debtConverter.redeemConversion(0, 0);

        (,uint dolaIOUAmountConverted,) = debtConverter.conversions(user, 0);
        uint exchangeRate = debtConverter.exchangeRateMantissa();

        assertEq(IERC20(DOLA).balanceOf(user), dolaBalance, "Dola balance changed after second redemption");
        assertEq(IERC20(address(debtConverter)).balanceOf(user), dolaIOUBalance, "Dola IOU balance changed after second redemption");
        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaIOUAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaIOUAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }

    function testRepaymentAndRedeemConversionWithNWeeklyRepayments(uint8 _repayments) public {
        vm.assume(_repayments < 520);
        vm.assume(_repayments > 1);
        uint256 repayments = uint256(_repayments);
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount * 100);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        uint debtService = debtConverter.outstandingDebt() / repayments;
        for(uint i = 0; i < repayments; i++){
            debtConverter.repayment(debtService);
        }
        //Repay dust left by division rounding error
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.conversions(user, 0);
        debtConverter.redeemConversion(0, 0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }

    function testRedeemConversionWhileSpecifyingEndEpoch() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        
        for (uint i = 0; i < 5; i++) {
            debtConverter.repayment(debtConverter.outstandingDebt()/5);
        }

        //Redeem DOLA IOUs on user
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 1);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 2);
        debtConverter.redeemConversion(0, 6);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConverted), "User balance less than 99.9% of dolaAmountConverted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConverted) * 1001/1000, "User balance more than 100.1% of dolaAmountConverted");
    }

    function testRedeemConversionFailsIfEndEpochIsInTheFuture() public {
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);

        vm.expectRevert(ThatEpochIsInTheFuture.selector);
        debtConverter.redeemConversion(0, 10);
    }

    function testRepaymentFailsWithMultipleAddressRepayments() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        uint epoch = debtConverter.repaymentEpoch();
        //Repay DOLA IOUs on random address, this should not trigger epoch change.
        vm.stopPrank();
        vm.startPrank(user2);
        gibDOLA(user2, dolaAmount);
        IERC20(DOLA).approve(address(debtConverter), type(uint).max);
        vm.expectRevert(OnlyOwner.selector);
        debtConverter.repayment(dolaAmount);
    }

    function testRepaymentAndRedeemConversionMultipleAddresses() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user2, anBtc, anBtcAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.stopPrank();
        vm.startPrank(user2);

        IERC20(anBtc).approve(address(debtConverter), anBtcAmount);
        debtConverter.convert(anBtc, anBtcAmount, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //Redeem DOLA IOUs for both users
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);

        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,,uint dolaRedeemableOne) = debtConverter.repayments(1);
        (,uint dolaAmountConvertedUser,) = debtConverter.conversions(user, 0);
        (,uint dolaAmountConvertedUser2,) = debtConverter.conversions(user2, 0);

        dolaRedeemablePerDolaOfDebt += dolaRedeemableOne;

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConvertedUser), "user1 balance less than 99.9% of amount converted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConvertedUser) * 1001/1000, "user1 balance more than 100.1% of amount converted");
        assertGe(IERC20(DOLA).balanceOf(user2) * 1001/1000, convertDolaIOUsToDola(dolaAmountConvertedUser2), "user2 balance less than 99.9% of amount converted");
        assertLe(IERC20(DOLA).balanceOf(user2), convertDolaIOUsToDola(dolaAmountConvertedUser2) * 1001/1000, "user2 balance more than 100.1% of amount converted");
    }

    function testRepaymentAndRedeemConversionMultipleAddressesStaggered() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user2, anBtc, anBtcAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user2);

        IERC20(anBtc).approve(address(debtConverter), anBtcAmount);
        debtConverter.convert(anBtc, anBtcAmount, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //Redeem DOLA IOUs for both users
        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,,uint dolaRedeemableOne) = debtConverter.repayments(1);
        (,uint dolaAmountConvertedUser,) = debtConverter.conversions(user, 0);
        (,uint dolaAmountConvertedUser2,) = debtConverter.conversions(user2, 0);
        IERC20(DOLA).balanceOf(address(debtConverter));
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);

        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);

        
        (,,uint dolaRedeemableTwo) = debtConverter.repayments(2);

        dolaRedeemablePerDolaOfDebt += dolaRedeemableOne + dolaRedeemableTwo;

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        debtConverter.outstandingDebt();
        IERC20(DOLA).balanceOf(address(debtConverter));
        IERC20(DOLA).balanceOf(user2);
        assertGe(IERC20(DOLA).balanceOf(user) * 1001/1000, convertDolaIOUsToDola(dolaAmountConvertedUser), "user1 balance less than 99.9% of amount converted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConvertedUser) * 1001/1000, "user1 balance more than 100.1% of amount converted");
        assertGe(IERC20(DOLA).balanceOf(user2) * 1001/1000, convertDolaIOUsToDola(dolaAmountConvertedUser2), "user2 balance less than 99.9% of amount converted");
        assertLe(IERC20(DOLA).balanceOf(user2), convertDolaIOUsToDola(dolaAmountConvertedUser2) * 1001/1000, "user2 balance more than 100.1% of amount converted");
    }

    function testRedeemMultipleConversions() public {
        //Convert anETH & anYfi to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user, anYfi, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        IERC20(anYfi).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        debtConverter.convert(anYfi, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //Redeem DOLA IOUs on user for both conversions
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        IERC20(DOLA).balanceOf(address(debtConverter));
        debtConverter.redeemConversion(1, 0);

        //Repay all outstanding DOLA debt
        vm.stopPrank();
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //Redeem DOLA IOUs for both conversions again
        vm.stopPrank();
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(1, 0);

        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,,uint dolaRedeemablePerDolaOne) = debtConverter.repayments(1);
        (,uint dolaAmountConvertedTotal,) = debtConverter.conversions(user, 0);
        (,uint dolaAmountConvertedYfi,) = debtConverter.conversions(user, 1);

        dolaRedeemablePerDolaOfDebt += dolaRedeemablePerDolaOne;
        dolaAmountConvertedTotal += dolaAmountConvertedYfi;

        //User should have all of their converted DOLA redeemed at this point.
        //  scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assertGe(IERC20(DOLA).balanceOf(user) * 1001 / 1000, convertDolaIOUsToDola(dolaAmountConvertedTotal), "User balance less than 99.9% of converted");
        assertLe(IERC20(DOLA).balanceOf(user), convertDolaIOUsToDola(dolaAmountConvertedTotal) * 1001 / 1000, "User balance more than 100.1% of converted");
    }

    function testAccrueInterest() public {
        vm.startPrank(gov);
        uint increase = 1e18;
        debtConverter.setExchangeRateIncrease(increase);

        //add on an extra day to account for division messing things up.
        vm.warp(block.timestamp + 366 days);

        uint prevRate = debtConverter.exchangeRateMantissa();
        debtConverter.accrueInterest();
        uint postRate = debtConverter.exchangeRateMantissa();

        assertGt(postRate, prevRate + increase, "Exchange rate increased less than 100% over 366 days");
        assertLt(postRate, prevRate * 202/100, "Exchange rate increased more than 101% over 366 days");
    }

    function testTransferFailsWhenToAddressIsNotWhitelisted() public {
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.expectRevert(TransferToAddressNotWhitelisted.selector);
        debtConverter.transfer(gov, 1);
    }

    function testTransferFromFailsWhenToAddressIsNotWhitelisted() public {
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.expectRevert(TransferToAddressNotWhitelisted.selector);
        debtConverter.transferFrom(user, gov, 1);
    }

    function testSweepTokensNotCallableByNonOwner() public {
        gibDOLA(address(debtConverter), 10);

        vm.startPrank(user);

        vm.expectRevert(OnlyGovernance.selector);
        debtConverter.sweepTokens(DOLA, 1);
    }

    function testSweepTokens() public {
        uint amount = 10;

        vm.startPrank(treasury);
        IERC20(DOLA).transfer(address(debtConverter), amount);
        uint prevBal = IERC20(DOLA).balanceOf(treasury);

        vm.stopPrank();
        vm.startPrank(gov);
        IERC20(DOLA).balanceOf(address(debtConverter));
        debtConverter.sweepTokens(DOLA, amount);

        assertEq(prevBal + amount, IERC20(DOLA).balanceOf(treasury), "Debt converter balance didn't increase by amount on repayment");
    }

    // Access Control

    function testSetExchangeRateIncreaseNotCallableByNonOwner() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyGovernance.selector);
        debtConverter.setExchangeRateIncrease(1e18);
    }

    function testSetOwnerNotCallableByNonGovernance() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyGovernance.selector);
        debtConverter.setOwner(user);
    }

    function testSetTreasuryNotCallableByNonGovernance() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyGovernance.selector);
        debtConverter.setTreasury(user);
    }

    function testSetGovernanceNotCallableByNonGovernance() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyGovernance.selector);
        debtConverter.setGovernance(user);
    }

    function testWhitelistTransferForNotCallableByNonOwner() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyOwner.selector);
        debtConverter.whitelistTransferFor(user);
    }

    //Helper Functions

    function gibAnTokens(address _user, address _anToken, uint _amount) internal {
        bytes32 slot;
        assembly {
            mstore(0, _user)
            mstore(0x20, 0xE)
            slot := keccak256(0, 0x40)
        }

        vm.store(_anToken, slot, bytes32(_amount));
    }

    function gibDOLA(address _user, uint _amount) internal {
        bytes32 slot;
        assembly {
            mstore(0, _user)
            mstore(0x20, 0x6)
            slot := keccak256(0, 0x40)
        }

        vm.store(DOLA, slot, bytes32(_amount));
    }

    function gibToken(address _token, address _user, uint _amount) public {
        bytes32 slot;
        assembly {
            mstore(0, _user)
            mstore(0x20, 0x0)
            slot := keccak256(0, 0x40)
        }

        vm.store(_token, slot, bytes32(uint256(_amount)));
    }

    function convertDolaIOUsToDola(uint dolaIOUs) public returns (uint) {
        return dolaIOUs * debtConverter.exchangeRateMantissa() / 1e18;
    }
}
