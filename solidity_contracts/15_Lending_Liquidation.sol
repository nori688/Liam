// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract LendingLiquidation {
    IERC20 public collateralToken;
    IERC20 public borrowToken;
    
    mapping(address => uint256) public collateralDeposited;
    mapping(address => uint256) public borrowedAmount;
    
    uint256 public collateralRatio; // минимальный кепил (например, 150%)
    uint256 public liquidationThreshold; // порог ликвидации (например, 130%)
    uint256 public liquidationBonus; // бонус ликвидатору (например, 105%)
    uint256 public interestRate;
    
    struct Loan {
        uint256 collateralAmount;
        uint256 borrowAmount;
        uint256 borrowTime;
        uint256 lastInterestUpdate;
    }
    
    mapping(address => Loan) public loans;
    mapping(address => bool) public authorizedLiquidators;

    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidation(
        address indexed borrower,
        address indexed liquidator,
        uint256 collateralSeized,
        uint256 debtRepaid
    );

    constructor(
        address _collateralToken,
        address _borrowToken,
        uint256 _collateralRatio,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _interestRate
    ) {
        collateralToken = IERC20(_collateralToken);
        borrowToken = IERC20(_borrowToken);
        collateralRatio = _collateralRatio; // 150
        liquidationThreshold = _liquidationThreshold; // 130
        liquidationBonus = _liquidationBonus; // 105
        interestRate = _interestRate; // 500 (5%)
        authorizedLiquidators[msg.sender] = true;
    }

    function depositCollateral(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        require(collateralToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        collateralDeposited[msg.sender] += _amount;
        
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
        
        uint256 maxBorrow = (loan.collateralAmount * 100) / collateralRatio;
        uint256 currentBorrow = loan.borrowAmount + _calculateInterest(msg.sender);
        
        require(currentBorrow + _amount <= maxBorrow, "Insufficient collateral");
        require(borrowToken.balanceOf(address(this)) >= _amount, "Insufficient liquidity");
        
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
        
        require(borrowToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        loan.borrowAmount = totalDebt - _amount;
        loan.lastInterestUpdate = block.timestamp;
        borrowedAmount[msg.sender] = loan.borrowAmount;
        
        emit Repay(msg.sender, _amount);
    }

    // Ликвидация позиции заемщика
    function liquidate(address _borrower, uint256 _debtToCover) external {
        require(authorizedLiquidators[msg.sender], "Not authorized liquidator");
        require(_borrower != msg.sender, "Cannot liquidate yourself");
        
        Loan storage loan = loans[_borrower];
        require(loan.borrowAmount > 0, "No debt to liquidate");
        
        uint256 totalDebt = loan.borrowAmount + _calculateInterest(_borrower);
        require(_debtToCover > 0 && _debtToCover <= totalDebt, "Invalid debt amount");
        
        // Проверяем, что позиция подлежит ликвидации
        uint256 currentRatio = (loan.collateralAmount * 100) / totalDebt;
        require(currentRatio < liquidationThreshold, "Position is healthy");
        
        // Рассчитываем сколько кепила можно забрать
        // collateralSeized = debtToCover * liquidationBonus / 100
        uint256 collateralSeized = (_debtToCover * liquidationBonus) / 100;
        require(collateralSeized <= loan.collateralAmount, "Insufficient collateral");
        
        // Ликвидатор погашает долг
        require(
            borrowToken.transferFrom(msg.sender, address(this), _debtToCover),
            "Debt repayment failed"
        );
        
        // Уменьшаем долг заемщика
        loan.borrowAmount = totalDebt - _debtToCover;
        loan.collateralAmount -= collateralSeized;
        collateralDeposited[_borrower] -= collateralSeized;
        
        // Передаем кепил ликвидатору
        require(
            collateralToken.transfer(msg.sender, collateralSeized),
            "Collateral transfer failed"
        );
        
        emit Liquidation(_borrower, msg.sender, collateralSeized, _debtToCover);
    }

    function _calculateInterest(address _user) internal view returns (uint256) {
        Loan memory loan = loans[_user];
        if (loan.borrowAmount == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - loan.lastInterestUpdate;
        uint256 secondsInYear = 365 days;
        
        return (loan.borrowAmount * interestRate * timeElapsed) / (10000 * secondsInYear);
    }

    function addLiquidator(address _liquidator) external {
        authorizedLiquidators[_liquidator] = true;
    }

    function removeLiquidator(address _liquidator) external {
        authorizedLiquidators[_liquidator] = false;
    }

    function canBeLiquidated(address _borrower) external view returns (bool) {
        Loan memory loan = loans[_borrower];
        if (loan.borrowAmount == 0) return false;
        
        uint256 totalDebt = loan.borrowAmount + _calculateInterest(_borrower);
        uint256 currentRatio = (loan.collateralAmount * 100) / totalDebt;
        
        return currentRatio < liquidationThreshold;
    }

    function getLiquidationInfo(address _borrower) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 currentRatio,
        bool liquidatable
    ) {
        Loan memory loan = loans[_borrower];
        debt = loan.borrowAmount + _calculateInterest(_borrower);
        collateral = loan.collateralAmount;
        
        if (debt > 0) {
            currentRatio = (collateral * 100) / debt;
            liquidatable = currentRatio < liquidationThreshold;
        } else {
            currentRatio = 0;
            liquidatable = false;
        }
    }
}
