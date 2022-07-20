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
    uint anTokenAmount = 50 * 10**18;
    uint anBtcAmount = 50 * 10**8;
    uint dolaAmount = 200 * 10**18;

    DebtConverter debtConverter;

    error TransferToAddressNotWhitelisted();
    error ConversionOccurredAfterGivenEpoch();
    error AlreadyRedeemedThisEpoch();
    error OnlyOwner();
    error InvalidDebtToken();
    
    function setUp() public {
        debtConverter = new DebtConverter(gov, treasury, oracle);

        vm.startPrank(gov);
        IERC20(DOLA).approve(address(debtConverter), type(uint256).max);
        comptroller._setTransferPaused(false);
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
        uint underlyingAmount = ICToken(anToken).balanceOfUnderlying(user);

        vm.startPrank(user);

        IERC20(anToken).approve(address(debtConverter), amount);
        debtConverter.convert(anToken, amount, 0);

        IFeed feed;
        if (anToken == anEth) {
            feed = ethFeed;
        } else if (anToken == anYfi) {
            feed = yfiFeed;
        } else if (anToken == anBtc) {
            feed = btcFeed;
        }

        uint decimals = 18;
        uint dolaToBeReceived = underlyingAmount * feed.latestAnswer();
        if (anToken == anBtc) {
            dolaToBeReceived = dolaToBeReceived * 10**2;
        } else {
            dolaToBeReceived = dolaToBeReceived / 10**decimals;
        }
        uint dolaIOUsReceived = debtConverter.balanceOf(user);
        uint dolaReceived = debtConverter.convertDolaIOUsToDola(dolaIOUsReceived);
        emit log_uint(dolaToBeReceived);
        emit log_uint(dolaReceived);
        assert(dolaReceived == dolaToBeReceived);
    }

    function testRedeemWithInsufficientDolaIOUs() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs & whitelist gov address for transfers for testing purposes
        vm.startPrank(gov);
        debtConverter.whitelistTransferFor(gov);
        debtConverter.repayment(dolaAmount);

        //transfer DOLA IOUs to gov. given 50e18 anTokenAmount, this will leave user with ~160 DOLA worth of IOUs
        //  with ~200 DOLA being claimable. Intended behavior is to redeem all remaining IOUs
        vm.startPrank(user);
        debtConverter.transfer(gov, ethFeed.latestAnswer() * 99/100 * 1e10);
        uint dolaRedeemable = debtConverter.balanceOfDola(user);
        debtConverter.redeemConversion(0, 0);

        uint dolaRedeemed = IERC20(DOLA).balanceOf(user);

        assert(debtConverter.balanceOf(user) == 0);
        assert(dolaRedeemable == dolaRedeemed);
    }

    function testRepaymentAndRedeemConversion() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(dolaAmount * 4);

        //Redeem DOLA IOUs on user
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assert(IERC20(DOLA).balanceOf(user) * 1001/1000 >= dolaAmountConverted);
        assert(IERC20(DOLA).balanceOf(user) <= dolaAmountConverted * 1001/1000);
    }

    function testZRedeemConversionWhileSpecifyingEndEpoch() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        
        for (uint i = 0; i < 5; i++) {
            debtConverter.repayment(dolaAmount);
        }

        //Redeem DOLA IOUs on user
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 1);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0, 2);
        debtConverter.redeemConversion(0, 6);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assert(IERC20(DOLA).balanceOf(user) * 1001/1000 >= dolaAmountConverted);
        assert(IERC20(DOLA).balanceOf(user) <= dolaAmountConverted * 1001/1000);
    }

    function testRepaymentAndRedeemConversionWithMultipleAddressRepayments() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        uint epoch = debtConverter.repaymentEpoch();
        //Repay DOLA IOUs on random address, this should not trigger epoch change.
        vm.startPrank(user2);
        gibDOLA(user2, dolaAmount);
        IERC20(DOLA).approve(address(debtConverter), type(uint).max);
        IERC20(DOLA).balanceOf(user2);
        debtConverter.repayment(dolaAmount);
        assert(epoch == debtConverter.repaymentEpoch());
    
        //Repay DOLA IOUs from gov address, this should trigger epoch change
        epoch = debtConverter.repaymentEpoch();
        vm.startPrank(gov);
        debtConverter.outstandingDebt();
        debtConverter.repayment(dolaAmount * 4);
        debtConverter.repayments(0);
        assert(epoch + 1 == debtConverter.repaymentEpoch());

        //Redeem DOLA IOUs on user
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);

        (,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assert(IERC20(DOLA).balanceOf(user) * 1001/1000 >= dolaAmountConverted);
        assert(IERC20(DOLA).balanceOf(user) <= dolaAmountConverted * 1001/1000);
    }

    function testRepaymentAndRedeemConversionMultipleAddresses() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user2, anBtc, anBtcAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.startPrank(user2);

        IERC20(anBtc).approve(address(debtConverter), anBtcAmount);
        debtConverter.convert(anBtc, anBtcAmount, 0);
        
        //Repay DOLA IOUs
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(dolaAmount * 4);

        //Redeem DOLA IOUs for both users
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);

        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,,uint dolaRedeemableOne) = debtConverter.repayments(1);
        (,uint dolaAmountConvertedUser,) = debtConverter.conversions(user, 0);
        (,uint dolaAmountConvertedUser2,) = debtConverter.conversions(user2, 0);

        dolaRedeemablePerDolaOfDebt += dolaRedeemableOne;

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        assert(IERC20(DOLA).balanceOf(user) * 1001/1000 >= dolaAmountConvertedUser);
        assert(IERC20(DOLA).balanceOf(user) <= dolaAmountConvertedUser * 1001/1000);
        assert(IERC20(DOLA).balanceOf(user2) * 1001/1000 >= dolaAmountConvertedUser2);
        assert(IERC20(DOLA).balanceOf(user2) <= dolaAmountConvertedUser2 * 1001/1000);
    }

    function testRepaymentAndRedeemConversionMultipleAddressesStaggered() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user2, anBtc, anBtcAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(dolaAmount * 2);

        vm.startPrank(user2);

        IERC20(anBtc).approve(address(debtConverter), anBtcAmount);
        debtConverter.convert(anBtc, anBtcAmount, 0);

        vm.startPrank(gov);
        debtConverter.repayment(dolaAmount * 2);

        //Redeem DOLA IOUs for both users
        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,,uint dolaRedeemableOne) = debtConverter.repayments(1);
        (,uint dolaAmountConvertedUser,) = debtConverter.conversions(user, 0);
        (,uint dolaAmountConvertedUser2,) = debtConverter.conversions(user2, 0);
        IERC20(DOLA).balanceOf(address(debtConverter));
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);
        vm.startPrank(user2);
        debtConverter.redeemConversion(0, 0);
        debtConverter.redeemConversion(0, 0);

        
        (,,uint dolaRedeemableTwo) = debtConverter.repayments(2);

        dolaRedeemablePerDolaOfDebt += dolaRedeemableOne + dolaRedeemableTwo;

        //scaled by 1001/1000 to add a 0.1% cushion & account for rounding
        debtConverter.outstandingDebt();
        IERC20(DOLA).balanceOf(address(debtConverter));
        IERC20(DOLA).balanceOf(user2);
        emit log_uint(dolaAmountConvertedUser2);
        assert(IERC20(DOLA).balanceOf(user) * 1001/1000 >= dolaAmountConvertedUser);
        assert(IERC20(DOLA).balanceOf(user) <= dolaAmountConvertedUser * 1001/1000);
        assert(IERC20(DOLA).balanceOf(user2) * 1001/1000 >= dolaAmountConvertedUser2);
        assert(IERC20(DOLA).balanceOf(user2) <= dolaAmountConvertedUser2 * 1001/1000);
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
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(dolaAmount * 8);

        //Redeem DOLA IOUs on user for both conversions
        vm.startPrank(user);
        debtConverter.redeemConversion(0, 0);
        IERC20(DOLA).balanceOf(address(debtConverter));
        debtConverter.redeemConversion(1, 0);

        //Repay all outstanding DOLA debt
        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        //Redeem DOLA IOUs for both conversions again
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
        assert(IERC20(DOLA).balanceOf(user) * 1001 / 1000 >= dolaAmountConvertedTotal);
        assert(IERC20(DOLA).balanceOf(user) <= dolaAmountConvertedTotal * 1001 / 1000);
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

        assert(postRate > prevRate + increase);
        assert(postRate < prevRate * 202/100);
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

        vm.expectRevert(OnlyOwner.selector);
        debtConverter.sweepTokens(DOLA, 1);
    }

    function testSweepTokens() public {
        uint amount = 10;

        vm.startPrank(treasury);
        IERC20(DOLA).transfer(address(debtConverter), amount);
        uint prevBal = IERC20(DOLA).balanceOf(treasury);

        vm.startPrank(gov);
        IERC20(DOLA).balanceOf(address(debtConverter));
        debtConverter.sweepTokens(DOLA, amount);

        assert(prevBal + amount == IERC20(DOLA).balanceOf(treasury));
    }

    // Access Control

    function testSetExchangeRateIncreaseNotCallableByNonOwner() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyOwner.selector);
        debtConverter.setExchangeRateIncrease(1e18);
    }

    function testSetOwnerNotCallableByNonOwner() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyOwner.selector);
        debtConverter.setOwner(user);
    }

    function testSetTreasuryNotCallableByNonOwner() public {
        vm.startPrank(user);

        vm.expectRevert(OnlyOwner.selector);
        debtConverter.setTreasury(user);
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
}
