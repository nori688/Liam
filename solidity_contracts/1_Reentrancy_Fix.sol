// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ReentrancyFix {
    mapping(address => uint256) public balances;
    
    // Reentrancy guard
    bool private locked;

    modifier noReentrancy() {
        require(!locked, "No reentrancy");
        locked = true;
        _;
        locked = false;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    // Уязвимая версия (для демонстрации)
    function withdrawVulnerable(uint256 _amount) external {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        // ВЗАИМОДЕЙСТВИЕ ПЕРЕД ЭФФЕКТАМИ - УЯЗВИМО!
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        // ЭФФЕКТЫ ПОСЛЕ ВЗАИМОДЕЙСТВИЯ
        balances[msg.sender] -= _amount;
    }

    // Исправленная версия - Checks-Effects-Interactions
    function withdrawSecure(uint256 _amount) external noReentrancy {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        // 1. CHECKS - проверка условий
        require(address(this).balance >= _amount, "Insufficient contract balance");
        
        // 2. EFFECTS - изменение состояния
        balances[msg.sender] -= _amount;
        
        // 3. INTERACTIONS - внешние вызовы в конце
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }
}
