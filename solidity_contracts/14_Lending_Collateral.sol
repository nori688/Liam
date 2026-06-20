// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract LendingCollateral {
    IERC20 public collateralToken;
    IERC20 public borrowToken;
    
    mapping(address => uint256) public collateralDeposited;
    mapping(address => uint256) public borrowedAmount;
    
    uint256 public collateralRatio; // в базисных пунктах (например, 150 = 150%)
    uint256 public interestRate; // годовая ставка в базисных пунктах
    
    struct Loan {
        uint256 collateralAmount;
        uint256 borrowAmount;
        uint256 borrowTime;
        uint256 lastInterestUpdate;
    }
    
    mapping(address => Loan) public loans;

    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);

    constructor(
        address _collateralToken,
        address _borrowToken,
        uint256 _collateralRatio,
        uint256 _interestRate
    ) {
        collateralToken = IERC20(_collateralToken);
        borrowToken = IERC20(_borrowToken);
        collateralRatio = _collateralRatio; // например 150 для 150%
        interestRate = _interestRate; // например 500 для 5%
    }

    function depositCollateral(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        
        require(
            collateralToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        
        collateralDeposited[msg.sender] += _amount;
        
        // Обновляем или создаем loan
        if (loans[msg.sender].collateralAmount == 0) {
            loans[msg.sender] = Loan({
                collateralAmount: _amount,
                borrowAmount: 0,
                borrowTime: block.timestamp,
                lastInterestUpdate: block.timestamp
            });
        } else {
            loans[msg.sender].collateralAmount += _amount;
        }
        
        emit DepositCollateral(msg.sender, _amount);
    }

    function borrow(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        
        Loan storage loan = loans[msg.sender];
        
        // Проверяем кепил
        uint256 maxBorrow = (loan.collateralAmount * 100) / collateralRatio;
        uint256 currentBorrow = loan.borrowAmount + _calculateInterest(msg.sender);
        
        require(currentBorrow + _amount <= maxBorrow, "Insufficient collateral");
        require(borrowToken.balanceOf(address(this)) >= _amount, "Insufficient liquidity");
        
        // Обновляем проценты
        loan.borrowAmount += _calculateInterest(msg.sender);
        loan.borrowAmount += _amount;
        loan.borrowTime = block.timestamp;
        loan.lastInterestUpdate = block.timestamp;
        
        borrowedAmount[msg.sender] = loan.borrowAmount;
        
        require(borrowToken.transfer(msg.sender, _amount), "Transfer failed");
        
        emit Borrow(msg.sender, _amount);
    }

    function repay(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        
        Loan storage loan = loans[msg.sender];
        
        uint256 totalDebt = loan.borrowAmount + _calculateInterest(msg.sender);
        require(totalDebt > 0, "No debt to repay");
        require(_amount <= totalDebt, "Repayment exceeds debt");
        
        require(
            borrowToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        
        loan.borrowAmount = totalDebt - _amount;
        loan.lastInterestUpdate = block.timestamp;
        borrowedAmount[msg.sender] = loan.borrowAmount;
        
        emit Repay(msg.sender, _amount);
    }

    function withdrawCollateral(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        require(collateralDeposited[msg.sender] >= _amount, "Insufficient collateral");
        
        Loan storage loan = loans[msg.sender];
        
        // Проверяем, что после вывода кепил достаточен
        uint256 newCollateral = loan.collateralAmount - _amount;
        uint256 maxBorrow = (newCollateral * 100) / collateralRatio;
        uint256 currentDebt = loan.borrowAmount + _calculateInterest(msg.sender);
        
        require(currentDebt <= maxBorrow, "Withdrawal would undercollateralize");
        
        loan.collateralAmount -= _amount;
        collateralDeposited[msg.sender] -= _amount;
        
        require(collateralToken.transfer(msg.sender, _amount), "Transfer failed");
        
        emit WithdrawCollateral(msg.sender, _amount);
    }

    function _calculateInterest(address _user) internal view returns (uint256) {
        Loan memory loan = loans[_user];
        if (loan.borrowAmount == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - loan.lastInterestUpdate;
        uint256 secondsInYear = 365 days;
        
        // Простой процент: principal * rate * time / (10000 * secondsInYear)
        return (loan.borrowAmount * interestRate * timeElapsed) / (10000 * secondsInYear);
    }

    function getLoanInfo(address _user) external view returns (
        uint256 collateral,
        uint256 borrowed,
        uint256 interest,
        uint256 totalDebt,
        uint256 maxBorrow
    ) {
        Loan memory loan = loans[_user];
        interest = _calculateInterest(_user);
        totalDebt = loan.borrowAmount + interest;
        maxBorrow = (loan.collateralAmount * 100) / collateralRatio;
        return (loan.collateralAmount, loan.borrowAmount, interest, totalDebt, maxBorrow);
    }

    function checkCollateralRatio(address _user) external view returns (bool isHealthy, uint256 currentRatio) {
        Loan memory loan = loans[_user];
        if (loan.borrowAmount == 0) return (true, 0);
        
        uint256 totalDebt = loan.borrowAmount + _calculateInterest(_user);
        if (totalDebt == 0) return (true, 0);
        
        currentRatio = (loan.collateralAmount * 100) / totalDebt;
        isHealthy = currentRatio >= collateralRatio;
    }
}
