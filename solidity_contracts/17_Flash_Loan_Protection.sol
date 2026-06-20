// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract FlashLoanProtection {
    IERC20 public token;
    mapping(address => uint256) public balances;
    
    uint256 public flashLoanFee; // в базисных пунктах (например, 5 = 0.05%)
    uint256 public constant MAX_FLASH_LOAN_AMOUNT = 1_000_000 * 10**18;
    uint256 public constant FLASH_LOAN_COOLDOWN = 1 hours;
    
    mapping(address => uint256) public lastFlashLoanTime;
    mapping(address => bool) public authorizedFlashLoanUsers;
    bool public flashLoansEnabled;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event FlashLoan(address indexed borrower, uint256 amount, uint256 fee);
    event FlashLoanRepaid(address indexed borrower, uint256 amount, uint256 fee);

    modifier onlyAuthorized() {
        require(authorizedFlashLoanUsers[msg.sender], "Not authorized for flash loans");
        _;
    }

    constructor(address _tokenAddress, uint256 _flashLoanFee) {
        token = IERC20(_tokenAddress);
        flashLoanFee = _flashLoanFee;
        flashLoansEnabled = true;
        authorizedFlashLoanUsers[msg.sender] = true;
    }

    function deposit(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        balances[msg.sender] += _amount;
        emit Deposit(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        balances[msg.sender] -= _amount;
        require(token.transfer(msg.sender, _amount), "Transfer failed");
        emit Withdraw(msg.sender, _amount);
    }

    // Защита 1: Ограничение суммы flash loan
    function flashLoan(uint256 _amount) external onlyAuthorized {
        require(flashLoansEnabled, "Flash loans disabled");
        require(_amount > 0, "Amount must be positive");
        require(_amount <= MAX_FLASH_LOAN_AMOUNT, "Exceeds max flash loan amount");
        require(token.balanceOf(address(this)) >= _amount, "Insufficient liquidity");
        
        // Защита 2: Cooldown между flash loans
        require(
            block.timestamp >= lastFlashLoanTime[msg.sender] + FLASH_LOAN_COOLDOWN,
            "Flash loan cooldown not met"
        );
        
        uint256 fee = (_amount * flashLoanFee) / 10000;
        uint256 totalRepayment = _amount + fee;
        
        // Сохраняем баланс до
        uint256 balanceBefore = token.balanceOf(address(this));
        
        // Передаем средства
        require(token.transfer(msg.sender, _amount), "Transfer failed");
        
        emit FlashLoan(msg.sender, _amount, fee);
        
        // Вызываем callback функцию заемщика
        // Заемщик должен вернуть totalRepayment
        (bool success, ) = msg.sender.call(
            abi.encodeWithSignature("receiveFlashLoan(uint256,uint256)", _amount, fee)
        );
        
        // Проверяем, что средства возвращены
        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "Flash loan not repaid");
        
        lastFlashLoanTime[msg.sender] = block.timestamp;
        
        emit FlashLoanRepaid(msg.sender, _amount, fee);
    }

    // Защита 3: Отключение flash loans в случае атаки
    function toggleFlashLoans(bool _enabled) external {
        flashLoansEnabled = _enabled;
    }

    // Защита 4: Управление авторизованными пользователями
    function setAuthorizedFlashLoanUser(address _user, bool _authorized) external {
        authorizedFlashLoanUsers[_user] = _authorized;
    }

    // Защита 5: Изменение комиссии
    function setFlashLoanFee(uint256 _newFee) external {
        require(_newFee <= 1000, "Fee too high"); // max 10%
        flashLoanFee = _newFee;
    }

    // Защита 6: Проверка на манипуляцию цен (oracle check)
    function flashLoanWithOracleCheck(
        uint256 _amount,
        uint256 _expectedPrice
    ) external onlyAuthorized {
        require(flashLoansEnabled, "Flash loans disabled");
        require(_amount <= MAX_FLASH_LOAN_AMOUNT, "Exceeds max amount");
        
        // Здесь должна быть проверка oracle
        // require(getOraclePrice() >= _expectedPrice, "Price manipulation detected");
        
        uint256 fee = (_amount * flashLoanFee) / 10000;
        
        require(token.transfer(msg.sender, _amount), "Transfer failed");
        
        (bool success, ) = msg.sender.call(
            abi.encodeWithSignature("receiveFlashLoan(uint256,uint256)", _amount, fee)
        );
        
        require(success, "Callback failed");
        
        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "Not repaid");
    }

    // Защита 7: Ограничение по проценту от TVL
    function flashLoanWithTVLLimit(uint256 _amount) external onlyAuthorized {
        uint256 totalTVL = token.balanceOf(address(this));
        uint256 maxPercentage = 30; // max 30% of TVL
        
        require(_amount <= (totalTVL * maxPercentage) / 100, "Exceeds TVL limit");
        
        // ... остальная логика flash loan
    }

    receive() external payable {}
}
