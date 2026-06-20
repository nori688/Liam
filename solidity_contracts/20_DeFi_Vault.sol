// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract DeFiVault {
    IERC20 public depositToken;
    
    mapping(address => uint256) public userBalances;
    mapping(address => uint256) public depositTimestamps;
    
    uint256 public totalDeposited;
    uint256 public totalShares;
    mapping(address => uint256) public userShares;
    
    uint256 public withdrawalFee; // в базисных пунктах
    uint256 public minDepositAmount;
    uint256 public maxDepositAmount;
    bool public paused;
    
    address public owner;
    address public feeRecipient;

    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares);
    event FeesCollected(address indexed recipient, uint256 amount);
    event Paused(bool paused);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier validAmount(uint256 _amount) {
        require(_amount >= minDepositAmount, "Amount below minimum");
        require(_amount <= maxDepositAmount, "Amount above maximum");
        _;
    }

    constructor(
        address _tokenAddress,
        uint256 _withdrawalFee,
        uint256 _minDeposit,
        uint256 _maxDeposit
    ) {
        depositToken = IERC20(_tokenAddress);
        withdrawalFee = _withdrawalFee;
        minDepositAmount = _minDeposit;
        maxDepositAmount = _maxDeposit;
        owner = msg.sender;
        feeRecipient = msg.sender;
    }

    // Безопасный депозит с Checks-Effects-Interactions
    function deposit(uint256 _amount) 
        external 
        whenNotPaused 
        validAmount(_amount) 
    {
        require(_amount > 0, "Amount must be positive");
        
        // CHECKS
        require(
            depositToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        
        // EFFECTS
        uint256 shares;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalShares) / totalDeposited;
        }
        
        userBalances[msg.sender] += _amount;
        userShares[msg.sender] += shares;
        depositTimestamps[msg.sender] = block.timestamp;
        
        totalDeposited += _amount;
        totalShares += shares;
        
        emit Deposit(msg.sender, _amount, shares);
    }

    // Безопасный вывод с защитой от reentrancy
    function withdraw(uint256 _shares) 
        external 
        whenNotPaused 
    {
        require(_shares > 0, "Shares must be positive");
        require(userShares[msg.sender] >= _shares, "Insufficient shares");
        
        // CHECKS
        uint256 withdrawAmount = (_shares * totalDeposited) / totalShares;
        require(withdrawAmount > 0, "Invalid withdraw amount");
        require(depositToken.balanceOf(address(this)) >= withdrawAmount, "Insufficient liquidity");
        
        // EFFECTS
        userShares[msg.sender] -= _shares;
        userBalances[msg.sender] -= withdrawAmount;
        
        totalShares -= _shares;
        totalDeposited -= withdrawAmount;
        
        // Вычисляем комиссию
        uint256 fee = 0;
        if (withdrawalFee > 0) {
            fee = (withdrawAmount * withdrawalFee) / 10000;
            withdrawAmount -= fee;
        }
        
        // INTERACTIONS
        require(depositToken.transfer(msg.sender, withdrawAmount), "Transfer failed");
        
        if (fee > 0) {
            require(depositToken.transfer(feeRecipient, fee), "Fee transfer failed");
            emit FeesCollected(feeRecipient, fee);
        }
        
        emit Withdraw(msg.sender, withdrawAmount, _shares);
    }

    // Получение информации о балансе
    function getUserBalance(address _user) external view returns (uint256 balance, uint256 shares) {
        return (userBalances[_user], userShares[_user]);
    }

    // Расчет стоимости шеров
    function getSharePrice() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalDeposited * 1e18) / totalShares;
    }

    // Управление паузой
    function pause() external onlyOwner {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Paused(false);
    }

    // Изменение параметров
    function setWithdrawalFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee too high"); // max 10%
        withdrawalFee = _newFee;
    }

    function setDepositLimits(uint256 _min, uint256 _max) external onlyOwner {
        require(_min < _max, "Invalid limits");
        minDepositAmount = _min;
        maxDepositAmount = _max;
    }

    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        feeRecipient = _newRecipient;
    }

    // Экстренный вывод владельцем
    function emergencyWithdraw(uint256 _amount) external onlyOwner {
        require(depositToken.balanceOf(address(this)) >= _amount, "Insufficient balance");
        require(depositToken.transfer(owner, _amount), "Transfer failed");
    }

    // Смена владельца
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        owner = _newOwner;
    }
}
