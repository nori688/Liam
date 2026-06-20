// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract OverflowProtection {
    mapping(address => uint256) public balances;
    uint256 public totalSupply;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens

    // В Solidity 0.8+ переполнение автоматически проверяется
    // Но для демонстрации показываем явные проверки

    function deposit(uint256 _amount) external {
        // Проверка на переполнение до сложения
        require(_amount > 0, "Amount must be positive");
        require(balances[msg.sender] + _amount >= balances[msg.sender], "Overflow detected");
        require(totalSupply + _amount >= totalSupply, "Total supply overflow");
        require(totalSupply + _amount <= MAX_SUPPLY, "Max supply exceeded");
        
        balances[msg.sender] += _amount;
        totalSupply += _amount;
    }

    function withdraw(uint256 _amount) external {
        // Проверка на антипереполнение до вычитания
        require(_amount > 0, "Amount must be positive");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        require(totalSupply >= _amount, "Insufficient total supply");
        
        balances[msg.sender] -= _amount;
        totalSupply -= _amount;
    }

    // Демонстрация уязвимости (для Solidity < 0.8)
    function vulnerableAdd(uint256 a, uint256 b) external pure returns (uint256) {
        // В старых версиях это может вызвать переполнение
        return a + b;
    }

    // Безопасное сложение с проверкой
    function safeAdd(uint256 a, uint256 b) external pure returns (uint256) {
        require(a + b >= a, "Overflow");
        return a + b;
    }

    // Безопасное вычитание с проверкой
    function safeSub(uint256 a, uint256 b) external pure returns (uint256) {
        require(a >= b, "Underflow");
        return a - b;
    }

    // Использование библиотеки SafeMath (для старых версий)
    function safeMul(uint256 a, uint256 b) external pure returns (uint256) {
        if (a == 0) return 0;
        require((a * b) / a == b, "Multiplication overflow");
        return a * b;
    }
}
