// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract DoubleWithdrawPrevention {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastWithdrawTime;
    mapping(address => uint256) public withdrawalNonce;
    
    uint256 public constant WITHDRAWAL_COOLDOWN = 1 hours;
    uint256 public constant MAX_WITHDRAWAL_PER_DAY = 1000 * 10**18;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount, uint256 nonce);

    function deposit() external payable {
        require(msg.value > 0, "Amount must be positive");
        balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    // Защита от double-withdraw с помощью nonce
    function withdrawWithNonce(uint256 _amount, uint256 _nonce) external {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        require(withdrawalNonce[msg.sender] == _nonce, "Invalid nonce");
        
        balances[msg.sender] -= _amount;
        withdrawalNonce[msg.sender] = _nonce + 1;
        
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit Withdraw(msg.sender, _amount, _nonce);
    }

    // Защита с помощью cooldown
    function withdrawWithCooldown(uint256 _amount) external {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        require(
            block.timestamp >= lastWithdrawTime[msg.sender] + WITHDRAWAL_COOLDOWN,
            "Withdrawal cooldown not met"
        );
        
        balances[msg.sender] -= _amount;
        lastWithdrawTime[msg.sender] = block.timestamp;
        
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit Withdraw(msg.sender, _amount, withdrawalNonce[msg.sender]);
    }

    // Защита с использованием Effects-Interactions паттерна
    function withdrawSecure(uint256 _amount) external {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        // EFFECTS - сначала меняем состояние
        balances[msg.sender] -= _amount;
        withdrawalNonce[msg.sender]++;
        
        // INTERACTIONS - потом внешний вызов
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit Withdraw(msg.sender, _amount, withdrawalNonce[msg.sender] - 1);
    }

    // Проверка на лимит вывода за день
    function withdrawWithDailyLimit(uint256 _amount) external {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        require(_amount <= MAX_WITHDRAWAL_PER_DAY, "Exceeds daily limit");
        
        // Проверка, что сегодня еще не выводили
        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        require(lastWithdrawTime[msg.sender] < dayStart, "Already withdrawn today");
        
        balances[msg.sender] -= _amount;
        lastWithdrawTime[msg.sender] = block.timestamp;
        
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit Withdraw(msg.sender, _amount, withdrawalNonce[msg.sender]);
    }
}
