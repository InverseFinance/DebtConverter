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
    error InsufficientDolaIOUs();
    error OnlyOwner();
    
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
        if (anToken == anBtc) {
            decimals = 8;
        }

        uint dolaToBeReceived = underlyingAmount * feed.latestAnswer() / 10 ** decimals;
        uint dolaIOUsReceived = debtConverter.balanceOf(user);
        uint dolaReceived = debtConverter.convertDolaIOUsToDola(dolaIOUsReceived);
        assert(dolaReceived == dolaToBeReceived);
    }

    function testRepaymentAndRedeem() public {
        //Convert anETH to DOLA IOUs
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);

        IERC20(anEth).approve(address(debtConverter), anTokenAmount);
        debtConverter.convert(anEth, anTokenAmount, 0);
        
        //Repay DOLA IOUs
        vm.startPrank(gov);
        debtConverter.setExchangeRateIncrease(1e18);
        debtConverter.repayment(dolaAmount);

        //Redeem DOLA IOUs on user
        vm.startPrank(user);
        debtConverter.redeem(0, 0);

        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,,uint dolaAmountConverted,) = debtConverter.conversions(user, 0);

        assert(IERC20(DOLA).balanceOf(user) >= dolaRedeemablePerDolaOfDebt * dolaAmountConverted / 1e18);
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
        for (uint i = 0; i < 4; i++) {
            debtConverter.repayment(dolaAmount);
        }

        //Redeem DOLA IOUs on user
        vm.startPrank(user);
        debtConverter.redeemConversion(0);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0);
        debtConverter.redeemConversion(0);

        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,uint dolaAmountConverted,,) = debtConverter.conversions(user, 0);

        assert(IERC20(DOLA).balanceOf(user) >= dolaRedeemablePerDolaOfDebt * dolaAmountConverted / 1e18);
    }

    function testRedeemMultipleConversions() public {
        //Convert anETH to DOLA IOUs
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
        for (uint i = 0; i < 4; i++) {
            debtConverter.repayment(dolaAmount * 2);
        }

        //Redeem DOLA IOUs on user
        vm.startPrank(user);
        debtConverter.redeemConversion(0);
        debtConverter.redeemConversion(1);

        vm.startPrank(gov);
        debtConverter.repayment(debtConverter.outstandingDebt());

        vm.startPrank(user);
        debtConverter.redeemConversion(0);
        debtConverter.redeemConversion(1);
        debtConverter.redeemConversion(0);
        debtConverter.redeemConversion(1);

        (,,uint dolaRedeemablePerDolaOfDebt) = debtConverter.repayments(0);
        (,uint dolaAmountConverted,,) = debtConverter.conversions(user, 0);

        assert(IERC20(DOLA).balanceOf(user) >= dolaRedeemablePerDolaOfDebt * dolaAmountConverted / 1e18);
    }

    function testRedeemFailsForEpochBeforeConversion() public {
        //Convert so there is outstandingDebt in the contract
        gibAnTokens(user, anEth, anTokenAmount * 3);

        vm.startPrank(user);
        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.startPrank(gov);
        debtConverter.repayment(dolaAmount);

        vm.startPrank(user);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.startPrank(gov);
        debtConverter.repayment(dolaAmount);

        //Attempt to redeem DOLA IOUs from user's 2nd conversion for first repayment epoch, should fail
        vm.startPrank(user);
        vm.expectRevert(ConversionOccurredAfterGivenEpoch.selector);
        debtConverter.redeem(1, 0);
    }
    
    function testRedeemFailsIfUserHasClaimedAllDolaForConversion() public {
        //Convert so there is outstandingDebt in the contract
        gibAnTokens(user, anEth, anTokenAmount);
        gibAnTokens(user2, anEth, anTokenAmount * 3);

        vm.startPrank(user2);
        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.startPrank(user);
        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.startPrank(gov);
        for (uint i = 0; i < 10; i++) {
            debtConverter.repayment(dolaAmount);
        }

        vm.startPrank(user);
        for (uint i = 0; i < 10; i++) {
            debtConverter.redeem(0, i);
        }

        vm.startPrank(user2);
        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, anTokenAmount * 2, 0);

        vm.startPrank(gov);
        for (uint i = 0; i < 10; i++) {
            debtConverter.repayment(dolaAmount * 2);
        }

        //Attempt to redeem DOLA IOUs from user's 2nd conversion for first repayment epoch, should fail
        vm.startPrank(user);

        for (uint i = 10; i < 20; i++) {
            (,,uint dolaAmountConverted, uint dolaAmountRedeemed) = debtConverter.conversions(user, 0);
            uint dolaToBeRedeemed = debtConverter.getRedeemableDolaForEpoch(user, 0, i);
            if (dolaAmountConverted < dolaToBeRedeemed + dolaAmountRedeemed) {
                vm.expectRevert(InsufficientDolaIOUs.selector);
            }
            debtConverter.redeem(0, i);
            // emit log_named_uint("DOLA balance of user", IERC20(DOLA).balanceOf(user));
        }
    }

    function testRedeemFailsForEpochThatHasAlreadyBeenRedeemed() public {
        //Convert so there is outstandingDebt in the contract
        gibAnTokens(user, anEth, anTokenAmount);

        vm.startPrank(user);
        IERC20(anEth).approve(address(debtConverter), type(uint).max);
        debtConverter.convert(anEth, anTokenAmount, 0);

        vm.startPrank(gov);
        debtConverter.repayment(dolaAmount);

        //Attempt to redeem DOLA IOUs from user's 2nd conversion for first repayment epoch, should fail
        vm.startPrank(user);
        debtConverter.redeem(0, 0);
        vm.expectRevert(AlreadyRedeemedThisEpoch.selector);
        debtConverter.redeem(0, 0);
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

        emit log_named_uint("prevRate", prevRate);
        emit log_named_uint("postRate", postRate);

        assert(postRate > prevRate + increase);
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
            mstore(0x20, 0x0)
            slot := keccak256(0, 0x40)
        }

        vm.store(DOLA, slot, bytes32(_amount));
    }
}
