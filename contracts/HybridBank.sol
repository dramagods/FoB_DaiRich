pragma solidity ^0.5.0;


import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./aave/interfaces/IAToken.sol";
import "./aave/interfaces/ILendingPool.sol";
import "./aave/interfaces/ILendingPoolAddressesProvider.sol";

contract HybridBank is Ownable {
    uint private clientCount;
    uint private totalDeposits;
    uint private totalInvested;

    struct Account {
        // Number of DAI tokens transferred and deposited to Hybrid Bank
        // TODO: We should allow other tokens too
        uint256 balance;
        uint256 investmentThreshold;
        uint256 minBalance;
        uint256 invested;
        bool isEnrolled;
    }
    mapping(address => Account) private accounts;

    // DAI Token used by the account
    IERC20 daiToken;
    // AAVE aDAI aToken receiving interests
    IAtoken adaiToken;
    // AAVE referral. We could add referrals to customers.
    // i.e. bringing new customers will earn more interest
    uint16 private referral;

    // TODO: Check this later
    // using SafeERC20 for IERC20;
    // using SafeMath for uint256;

    // Retrieve LendingPool address from
    // https://github.com/masaun/prediction-ticket/blob/master/contracts/StakingByAToken.sol

    /// Retrieve LendingPool address
    ILendingPoolAddressesProvider public lendingPoolAddressProvider;

    // Log the event about a deposit being made by an address and its amount
    event LogDepositMade(address indexed accountAddress, uint256 amount);
    event LogLendingPoolCore(address lendingPoolCore);
    event LogLendingPool(ILendingPool lendingPoolAddressProvider);
    event LogInvestmentMade(address indexed accountAddress, uint256 amount);
    event LogApproveERC20ToAAVE(address indexed from, address indexed to, IERC20 token);

    modifier isEnrolled() {
        require(
            accounts[msg.sender].isEnrolled,
            "Address must be enrolled in the bank"
        );
        _;
    }

    constructor(ILendingPoolAddressesProvider _lendingPoolAddressesProvider,
                IERC20 _inboundCurrency,
                IAtoken _interestCurrency
                )
                public {

        daiToken = _inboundCurrency;
        adaiToken = _interestCurrency;
        lendingPoolAddressProvider = _lendingPoolAddressesProvider;

        // Initialise variables
        clientCount = 0;
        totalDeposits = 0;
        totalInvested = 0;

        // Allow lending pool convert DAI deposited on this contract to aDAI on lending pool
        address lendingPoolCore = lendingPoolAddressProvider.getLendingPoolCore();
        emit LogLendingPoolCore(lendingPoolCore);

        uint MAX_ALLOWANCE = 2**256 - 1;
        daiToken.approve(lendingPoolCore, MAX_ALLOWANCE);
        emit LogApproveERC20ToAAVE(msg.sender, lendingPoolCore, daiToken);
      }

    /// @notice Enroll a customer with the bank,
    /// @return The balance of the user after enrolling
    function enroll() public {
        accounts[msg.sender].isEnrolled = true;
        accounts[msg.sender].balance = 0;
        accounts[msg.sender].invested = 0;
        clientCount++;
    }

    /// @notice Deposit ether into bank
    /// @return The balance of the user after the deposit is made
    function deposit(uint256 _amount)
        public
        isEnrolled
        returns (uint256, uint256) {

        uint256 amountToInvest;

        // Check allowance from DAI contract to transfer DAI to this contract
        require(daiToken.allowance(msg.sender, address(this)) >= _amount, "You need to have allowance to do transfer DAI on this smart contract");

        // Move DAI from user wallet to HybridBank
        require(daiToken.transferFrom(msg.sender, address(this), _amount) == true, "Transfer failed");

        // Add deposit amount to balance
        accounts[msg.sender].balance += _amount;

        totalDeposits += _amount;

        // If current balance is higher than investmentThresdhold
        if ((accounts[msg.sender].investmentThreshold > 0) && (accounts[msg.sender].balance > accounts[msg.sender].investmentThreshold))  {
            amountToInvest = accounts[msg.sender].balance - accounts[msg.sender].investmentThreshold;
            _investInAAVE(amountToInvest);
        }

        emit LogDepositMade(msg.sender, _amount);
        return (accounts[msg.sender].balance, accounts[msg.sender].invested);
    }

    // @notice User withdraw DAI from Hybrid Bank to DAI smart contract
    // @returns balance and invested amount
    function withdraw(uint256 _amount)
        public
        isEnrolled
        returns (uint256, uint256) {

        // Check account balance is enough to transfer
        require(accounts[msg.sender].balance >= _amount, "Your balance is lower than the amount you want to transfer.");
 
        // Mode DAI from HybridBank to DAI user wallet
        require(daiToken.transfer(msg.sender, _amount) == true, "Transfer failed");

        // Remove amount from user balance
        accounts[msg.sender].balance -= _amount;
        
        return (accounts[msg.sender].balance, accounts[msg.sender].invested);
      }


    function _investInAAVE(uint256 _amount) internal {
        ILendingPool lendingPool = ILendingPool(lendingPoolAddressProvider.getLendingPool());

        emit LogLendingPool(lendingPool);

        lendingPool.deposit(address(daiToken), _amount, 0);
        accounts[msg.sender].invested += _amount;
        accounts[msg.sender].balance -= _amount;
        totalInvested += _amount;

        emit LogInvestmentMade(msg.sender, _amount);

    }

    /// @notice pay with DAI to someone for something
    /// @return balance
    function pay(address _recipient, uint256 _amount)
        public
        isEnrolled
        returns (uint256 balance, uint256 invested) {

        uint256 amountToBorrow;

        if (_amount <= accounts[msg.sender].balance) {
            // Pay in DAI to recipient
            // TODO: This will send DAI from Hybrid Bank to Recipient
            // TODO: I think it should be more personal, i.e. sent money from person address
            daiToken.transfer(_recipient, _amount);

            // Update balances
            accounts[msg.sender].balance -= _amount;
            totalDeposits -= _amount;
        }
        // We don't have enough money.
        else {
            // Find out the amount we need
            amountToBorrow = _amount - accounts[msg.sender].balance + accounts[msg.sender].minBalance ;

            //  Do we have enough money in the investment account?
            if (accounts[msg.sender].invested > amountToBorrow) {
                // Get amount needed from AAVE
                _redeemInvestmentAAVE(amountToBorrow);
            }
            // We don't have enough in our investment account so
            // we transfer from DAI if we have enough allowance
            else {
                // Check allowance from DAI contract to transfer DAI to this contract
                require(daiToken.allowance(msg.sender, address(this)) >= amountToBorrow, "You don't have enough funds. You need to have allowance to do transfer DAI on this smart contract");

                // Move DAI from user wallet to HybridBank
                require(daiToken.transferFrom(msg.sender, address(this), amountToBorrow) == true, "DAI Transfer failed");

                // Update Balances
                accounts[msg.sender].balance += amountToBorrow;
                totalDeposits += amountToBorrow;
            }
            // We have now enough balance to pay
            // Pay in DAI to recipient
            daiToken.transfer(_recipient, _amount);

            // Update Balances
            accounts[msg.sender].balance -= _amount;
            totalDeposits -= _amount;
        }
        if (accounts[msg.sender].balance < accounts[msg.sender].minBalance) {
            _topUp();
        }

        return (accounts[msg.sender].balance, accounts[msg.sender].invested);
    }

    function _redeemInvestmentAAVE(uint256 _amount)
        internal {

        adaiToken.redeem(_amount);
        accounts[msg.sender].invested -= _amount;
        accounts[msg.sender].balance += _amount;
        totalInvested -= _amount;

    }

    function _topUp()
        internal {
        // Topup functionality. If balance is below minBalance get money back from AAVE if possible
        // If there's not enough money in AAVE, two options:
        // 1. Check if we have allowance from DAI contract, if we have enough we transfer money from DAI contract
        // 2. Check options for a micro loan
        uint256 amountToBorrow;

        if (accounts[msg.sender].balance < accounts[msg.sender].minBalance) {
            // Find out the amount we need
            amountToBorrow = accounts[msg.sender].minBalance - accounts[msg.sender].balance;
            if (accounts[msg.sender].invested > amountToBorrow) {
                // Get amount needed from AAVE
                _redeemInvestmentAAVE(amountToBorrow);

                // Update Balances
                accounts[msg.sender].invested -= amountToBorrow;
                accounts[msg.sender].balance += amountToBorrow;
            }
            else {
                // Check allowance from DAI contract to transfer DAI to this contract
                require(daiToken.allowance(msg.sender, address(this)) >= amountToBorrow, "You need to have allowance to do transfer DAI on this smart contract");

                // Move DAI from user wallet to HybridBank
                require(daiToken.transferFrom(msg.sender, address(this), amountToBorrow) == true, "Transfer failed");

                // Add deposit amount to balance
                accounts[msg.sender].balance += amountToBorrow;

                totalDeposits += amountToBorrow;

            // TODO: Micro credit or Flash Loan
            }
        }
    }

    /// @notice Just reads balances of the account requesting, so "constant"
    /// @return The balance of the user, amount deposited, invested and invested plus interests
    function balance()
        public view
        isEnrolled
        returns (uint256, uint256, uint256) {

        uint256 percentageInvested;
        uint256 investedWithInterests;
        if (accounts[msg.sender].invested > 0) {
            percentageInvested = accounts[msg.sender].invested / totalInvested;
            investedWithInterests = adaiToken.balanceOf(address(this)) * percentageInvested;
        }
        else
        {
            investedWithInterests = 0;
        }
        return (accounts[msg.sender].balance, accounts[msg.sender].invested, investedWithInterests);
    }

    /// @notice Set investment threshold
    /// @return investmentThresholdSet
    function setInvestmentThreshold(uint256 investmentThreshold) 
        public
        isEnrolled
        returns (uint256 investmentThresholdSet) 
    {
        accounts[msg.sender].investmentThreshold = investmentThreshold;
        return accounts[msg.sender].investmentThreshold;
    }
    
    /// @notice reads the get investmentThreshold 
    /// @return investmentThreshold
    function getInvestmentThreshold()
        public view
        isEnrolled
        returns (uint256) {
        return accounts[msg.sender].investmentThreshold;
    }

    /// @notice reads the get account balance
    /// @return balance
    function getAccountBalance()
        public view
        isEnrolled
        returns (uint256) {
        return accounts[msg.sender].balance;
    }

    /// @notice reads the get investment WITHOUT interests
    /// @return investment
    function getInvestedAmount()
        public view
        isEnrolled
        returns (uint256) {
        return accounts[msg.sender].invested;
    }

    /// @notice Set minBalance 
    /// @return minBalanceSet
    function setMinBalance(uint256 minBalance) 
        public
        isEnrolled
        returns (uint256 minBalanceSet) {

        accounts[msg.sender].minBalance = minBalance;
        return accounts[msg.sender].minBalance;
    }
    
    /// @notice reads the get minBalance
    /// @return minBalance
    function getMinBalance()
        public view
        isEnrolled
        returns (uint256) {
        return accounts[msg.sender].minBalance;
    }

    /// @notice reads the Total amount deposited in the Hybrid Bank
    /// @return totalDeposits
    function getTotalDeposits()
        public view
        returns (uint256) {
        return totalDeposits;
    }

    /// @notice reads the Total amount invested without interests
    /// @return totalDeposits
    function getTotalInvested()
        public view
        returns (uint256) {
        return totalInvested;
    }

    /// @notice reads the Hybrid Bank DAI balance
    /// @return DAI balance
    function getContractDAIBalance()
        public view
        returns (uint256) {
        return daiToken.balanceOf(address(this));
    }

    /// @notice Just reads balances of the aDai token
    /// @return The balance of the total amount invested in AAVE WITH interests
    function getContractAAVEBalanceOf()
        public view
        onlyOwner
        returns(uint256) {
        return adaiToken.balanceOf(address(this));
    }

    /// @notice Just reads balances of the aDai token
    /// @return The balance of the total amount invested in aDAI token WITHOUT interests
    function getContractAAVEprincipalBalanceOf()
        public view
        onlyOwner
        returns(uint256) {
        return adaiToken.principalBalanceOf(address(this));
    }

    /// @notice Just reads ReserveConfigurationData
    /// @return Reserve Configuration Data
    function getContractAAVEReserveConfigurationData()
        public
        onlyOwner
        returns ( uint256 ltv, uint256 liquidationThreshold, uint256 liquidationDiscount, address interestRateStrategyAddress, bool usageAsCollateralEnabled, bool borrowingEnabled, bool fixedBorrowRateEnabled, bool isActive ) {

        ILendingPool lendingPool = ILendingPool(lendingPoolAddressProvider.getLendingPool());
        emit LogLendingPool(lendingPool);
        return lendingPool.getReserveConfigurationData(address(daiToken));

    }

    /// @notice Just reads getReserveData
    /// @return Reserve Data
    function getContractAAVEReserveData()
        public
        onlyOwner
        returns ( uint256 totalLiquidity, uint256 availableLiquidity, uint256 totalBorrowsFixed, uint256 totalBorrowsVariable, uint256 liquidityRate, uint256 variableBorrowRate, uint256 fixedBorrowRate, uint256 averageFixedBorrowRate, uint256 utilizationRate, uint256 liquidityIndex, uint256 variableBorrowIndex, address aTokenAddress, uint40 lastUpdateTimestamp ) {

        ILendingPool lendingPool = ILendingPool(lendingPoolAddressProvider.getLendingPool());
        emit LogLendingPool(lendingPool);
        return lendingPool.getReserveData(address(daiToken));

    }

    /// @notice Just reads getUserReserveData
    /// @return User Reserve Data
    function getContractAAVEUserReserveData()
        public
        onlyOwner
        returns ( uint256 currentATokenBalance, uint256 currentUnderlyingBalance, uint256 currentBorrowBalance, uint256 principalBorrowBalance, uint256 borrowRateMode, uint256 borrowRate, uint256 liquidityRate, uint256 originationFee, uint256 variableBorrowIndex, uint256 lastUpdateTimestamp, bool usageAsCollateralEnabled ) {

        ILendingPool lendingPool = ILendingPool(lendingPoolAddressProvider.getLendingPool());
        emit LogLendingPool(lendingPool);
        return lendingPool.getUserReserveData(address(daiToken), address(this));

    }

    /// @notice Just reads getUserAccountData
    /// @return User Account Data
    function getContractAAVEUserAccountData()
        public
        onlyOwner
        returns ( uint256 totalLiquidityETH, uint256 totalCollateralETH, uint256 totalBorrowsETH, uint256 availableBorrowsETH, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor ) {

        ILendingPool lendingPool = ILendingPool(lendingPoolAddressProvider.getLendingPool());
        emit LogLendingPool(lendingPool);
        return lendingPool.getUserAccountData(address(this));

    }

    /// @notice reads the Hybrid bank clients count
    /// @return clientCount
    function getClientCount()
        public view
        onlyOwner
        returns (uint256) {

        return clientCount;
    }

    /// @notice reads the enroll status
    /// @return bool
    function isAccountEnrolled()
        public view
        returns (bool) {
        return accounts[msg.sender].isEnrolled;
    }
}
