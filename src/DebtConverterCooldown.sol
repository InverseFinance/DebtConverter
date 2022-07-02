pragma solidity ^0.8.0;

import { IOracle } from "./interfaces/IOracle.sol";
import { ICToken } from "./interfaces/ICToken.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IFeed } from "./interfaces/IFeed.sol";

contract DebtConverterCooldown is ERC20 {
    //Current amount of DOLA-denominated debt accrued by the DebtConverter contract.
    uint public outstandingDebt;

    //Cumulative amount of DOLA-denominated debt accrued by the DebtConverter contract over its lifetime.
    uint public cumDebt;

    //Cumulative amount of DOLA repaid to the DebtConverter contract over its lifetime.
    uint public cumDolaRepaid;

    //Exchange rate of DOLA IOUs to DOLA scaled by 1e18. Default is 1e18.
    //DOLA IOU amount * exchangeRateMantissa / 1e18 = DOLA amount received on redemption
    //Bad Debt $ amount * 1e18 / exchangeRateMantissa = DOLA IOUs received on conversion
    uint public exchangeRateMantissa;

    //The amount that exchangeRateMantissa will increase every second. This is how “interest” is accrued.
    uint public exchangeRateIncreasePerSecond;

    //Timestamp of the last time `accrueInterest()` was called.
    uint public lastAccrueInterestTimestamp;

    //Amount of DOLA claimable per DOLA IOU.
    uint public dolaClaimablePerToken;

    //user address => total amount of debt converted denominated in $.
    mapping(address => uint) public totalDebtConverted;

    //user address => total DOLA/DOLA IOUs redeemed.
    mapping(address => uint) public totalDolaRedeemed;

    //user address => bool. True if DOLA IOU transfers to this address are allowed, false by default.
    mapping(address => bool) public transferWhitelist;

    //Can call privileged functions.
    address public owner;

    //Treasury address buying the debt.
    address public treasury;

    //Frontier master oracle.
    IOracle public oracle;

    //DOLA contract
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant anEth = 0x697b4acAa24430F254224eB794d2a85ba1Fa1FB8;
    address public constant anYfi = 0xde2af899040536884e062D3a334F2dD36F34b4a4;
    address public constant anBtc = 0x17786f3813E6bA35343211bd8Fe18EC4de14F28b;

    //Errors
    error ToAddressNotWhitelisted();
    error OnlyOwner();
    error InsufficientDebtTokens();
    error InvalidDebtToken();
    error DolaAmountLessThanMinOut();
    error InsufficientDolaIOUs();
    error InsufficientDebtToBeRepaid();

    //Events
    event NewOwner(address owner);
    event NewTreasury(address treasury);
    event NewTransferWhitelistAddress(address whitelistedAddr);
    event Repayment(uint dolaAmount);
    event Redemption(address user, uint dolaAmount);
    event Conversion(address user, address anToken, uint dolaAmount);
    event Logg(string str, uint num);

    constructor(address _owner, address _treasury, address _oracle) ERC20("DOLA IOU", "DOLAIOU") {
        owner = _owner;
        treasury = _treasury;
        oracle = IOracle(_oracle);
        exchangeRateMantissa = 1e18;
        lastAccrueInterestTimestamp = block.timestamp;
    }

    modifier onlyOwner() {
        if ( msg.sender != owner ) revert OnlyOwner();
        _;
    }

    /*
     * @notice function for converting bad debt anTokens to DOLA IOU tokens.
     * @param anToken Address of the bad debt anToken to be converted
     * @param amount Amount of `token` to be converted. 0 = max
     * @param minOut Minimum DOLA amount worth of DOLA IOUs to be received. Will revert if actual amount is lower.
     */
    function convert(address anToken, uint amount, uint minOut) external {
        uint anTokenBal = IERC20(anToken).balanceOf(msg.sender);
        if (amount == 0) amount = anTokenBal;

        if (anToken != anYfi && anToken != anBtc && anToken != anEth) revert InvalidDebtToken();
        if (anTokenBal < amount) revert InsufficientDebtTokens();

        //Accrue interest so exchange rates are fresh
        accrueInterest();

        //Calculate DOLA/DOLA IOU amounts owed. `underlyingAmount` * underlying price of anToken cancels out decimals
        uint underlyingAmount = ICToken(anToken).balanceOfUnderlying(msg.sender);
        uint dolaValueOfDebt = (oracle.getUnderlyingPrice(anToken) * underlyingAmount) / (10 ** 28);
        uint dolaIOUsOwed = dolaIOUsPerDola(dolaValueOfDebt);

        if (dolaValueOfDebt < minOut) revert DolaAmountLessThanMinOut();

        totalDebtConverted[msg.sender] += dolaValueOfDebt;
        outstandingDebt += dolaValueOfDebt;
        cumDebt += dolaValueOfDebt;

        updateDolaClaimablePerToken();

        _mint(msg.sender, dolaIOUsOwed);
        require(IERC20(anToken).transferFrom(msg.sender, address(this), amount), "failed to transfer anTokens");

        emit Conversion(msg.sender, anToken, dolaValueOfDebt);
    }

    /*
     * @notice function for repaying DOLA to this contract. Callable by anyone.
     * @param amount Amount of DOLA to repay & transfer to this contract.
     */
    function repayment(uint amount) external {
        if (amount > outstandingDebt) revert InsufficientDebtToBeRepaid();

        IERC20(DOLA).transferFrom(msg.sender, address(this), amount);

        outstandingDebt -= amount;
        cumDolaRepaid += amount;

        accrueInterest();
        updateDolaClaimablePerToken();

        emit Repayment(amount);
    }

    /*
     * @notice Function for redeeming DOLA IOUs for DOLA. 
     */
    function redeem() external {
        updateDolaClaimablePerToken();

        uint claimableDola = getClaimableDola(msg.sender);
        uint dolaIOUAmountRequired = dolaIOUsPerDola(claimableDola);

        if (dolaIOUAmountRequired > balanceOf(msg.sender)) revert InsufficientDolaIOUs();

        totalDolaRedeemed[msg.sender] += claimableDola;

        _burn(msg.sender, dolaIOUAmountRequired);
        IERC20(DOLA).transfer(msg.sender, claimableDola);

        emit Redemption(msg.sender, claimableDola);
    }

    /*
     * @notice function for accounting interest of DOLA IOU tokens. Called by convert(), repayment(), and redeem().
     * @dev only will apply rate increase once per block.
     */
    function accrueInterest() public {
        if(block.timestamp != lastAccrueInterestTimestamp) {
            uint rateIncrease = (block.timestamp - lastAccrueInterestTimestamp) * exchangeRateIncreasePerSecond;
            exchangeRateMantissa += rateIncrease;

            emit Logg("manti", exchangeRateMantissa);

            lastAccrueInterestTimestamp = block.timestamp;
        }
    }

    /*
     * @notice function for updating `dolaClaimablePerToken`. Ratio of cumulative DOLA repaid / cumulative debt
     */
    function updateDolaClaimablePerToken() internal {
        if (cumDebt > 0) {
            dolaClaimablePerToken = cumDolaRepaid * 1e18 / cumDebt;
        }
    }

    /*
     * @notice function for calculating claimable DOLA of an account
     * @param _addr Address to view claimable DOLA of
     */
    function getClaimableDola(address _addr) public returns (uint) {
        uint userRedeemedDola = totalDolaRedeemed[_addr];
        uint userConvertedDebt = totalDebtConverted[_addr];
        uint pctDolaClaimed = userRedeemedDola / userConvertedDebt;

        emit Logg("redeemed", userRedeemedDola);
        emit Logg("converted", userConvertedDebt);

        emit Logg("pct", pctDolaClaimed);
        emit Logg("per toke", dolaClaimablePerToken);

        if (pctDolaClaimed < dolaClaimablePerToken) {
            return ((userConvertedDebt * dolaClaimablePerToken / 1e18) - userRedeemedDola);
        }

        return 0;
    }

    /*
     * @notice function for calculating amount of DOLA IOUs equal to a given DOLA amount.
     * @param dola DOLA amount to be converted to DOLA IOUs
     */
    function dolaIOUsPerDola(uint dola) public view returns (uint) {
        return dola * 1e18 / exchangeRateMantissa;
    }

    /*
     * @notice function for calculating amount of DOLA IOUs equal to a given DOLA amount.
     * @param dola DOLA amount to be converted to DOLA IOUs
     */
    function dolaPerDolaIOU(uint dolaIOUs) public view returns (uint) {
        return dolaIOUs * 1e18 / exchangeRateMantissa;
    }

    function getClaimableDola() public view returns (uint) {
        return (totalDebtConverted[msg.sender] * dolaClaimablePerToken) - totalDolaRedeemed[msg.sender];
    }

    // Revert if `to` address is not whitelisted. Transfers between users are not enabled.
    function transfer(address to, uint amount) public override returns (bool) {
        if (!transferWhitelist[to]) revert ToAddressNotWhitelisted();

        return super.transfer(to, amount);
    }

    // Revert if `to` address is not whitelisted. Transfers between users are not enabled.
    function transferFrom(address from, address to, uint amount) public override returns (bool) {
        if (!transferWhitelist[to]) revert ToAddressNotWhitelisted();

        return super.transferFrom(from, to, amount);
    }

    /*
     * @notice function for transferring `amount` of `token` to the `treasury` address from this contract
     * @param token Address of the token to be transferred out of this contract
     * @param amount Amount of `token` to be transferred out of this contract, 0 = max
     */
    function sweepTokens(address token, uint amount) external onlyOwner {
        if (amount == 0) { 
            IERC20(token).transfer(treasury, IERC20(token).balanceOf(address(this)));
        } else {
            IERC20(token).transfer(treasury, amount);
        }
    }

    /*
     * @notice function for setting rate at which `exchangeRateMantissa` increases every year
     * @param increasePerYear The amount `exchangeRateMantissa` will increase every year. 1e18 is the default exchange rate.
     */
    function setExchangeRateIncrease(uint increasePerYear) public onlyOwner {
        exchangeRateIncreasePerSecond = increasePerYear / 365 days;
    }

    /*
     * @notice function for setting owner address.
     * @param newOwner Address that will become the new owner of the contract.
     */
    function setOwner(address newOwner) public onlyOwner {
        owner = newOwner;

        emit NewOwner(newOwner);
    }

    /*
     * @notice function for setting treasury address.
     * @param newTreasury Address that will be set as the new treasury of the contract.
     */
    function setTreasury(address newTreasury) public onlyOwner {
        treasury = newTreasury;

        emit NewTreasury(newTreasury);
    }

    /*
     * @notice function for whitelisting IOU token transfers to certain addresses.
     * @param whitelistedAddress Address to be added to whitelist. IOU tokens will be able to be transferred to this address.
     */
    function whitelistTransferFor(address whitelistedAddress) public onlyOwner {
        transferWhitelist[whitelistedAddress] = true;

        emit NewTransferWhitelistAddress(whitelistedAddress);
    }
}