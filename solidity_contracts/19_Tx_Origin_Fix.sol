// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TxOriginVulnerable {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    // УЯЗВИМАЯ ФУНКЦИЯ - использует tx.origin
    function withdrawAll() external {
        require(tx.origin == owner, "Not owner");
        payable(msg.sender).transfer(address(this).balance);
    }

    receive() external payable {}
}

// Атакующий контракт
contract AttackContract {
    address public victim;

    constructor(address _victim) {
        victim = _victim;
    }

    function attack() external {
        // Если владелец вызовет эту функцию, tx.origin будет владельцем
        // но msg.sender будет этим контрактом
        TxOriginVulnerable(victim).withdrawAll();
    }

    receive() external payable {
        // Получаем украденные средства
    }
}

// ИСПРАВЛЕННАЯ ВЕРСИЯ
contract TxOriginSecure {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ИСПРАВЛЕННАЯ ФУНКЦИЯ - использует msg.sender
    function withdrawAll() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    // Дополнительная защита - проверка на контракт
    modifier notContract() {
        uint256 size;
        assembly {
            size := extcodesize(msg.sender)
        }
        require(size == 0, "No contracts allowed");
        _;
    }

    function safeWithdraw(uint256 _amount) external onlyOwner notContract {
        require(_amount > 0, "Amount must be positive");
        require(address(this).balance >= _amount, "Insufficient balance");
        
        payable(owner).transfer(_amount);
    }

    receive() external payable {}
}

// Еще более безопасный вариант с reentrancy guard
contract TxOriginSecureAdvanced {
    address public owner;
    bool private locked;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier noReentrancy() {
        require(!locked, "Reentrancy detected");
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        owner = msg.sender;
    }

    function withdrawAll() external onlyOwner noReentrancy {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance");
        
        payable(owner).transfer(balance);
    }

    function withdraw(uint256 _amount) external onlyOwner noReentrancy {
        require(_amount > 0, "Amount must be positive");
        require(address(this).balance >= _amount, "Insufficient balance");
        
        payable(owner).transfer(_amount);
    }

    receive() external payable {}
}

// Проверка на контракт
contract ContractCheck {
    function isContract(address _addr) external view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    // Исключение для конструктора (когда size == 0 но это контракт)
    function isContractSafe(address _addr) external view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        // Если size > 0 - это контракт
        // Если size == 0 и _addr != tx.origin - это контракт в конструкторе
        return size > 0 || (_addr != tx.origin && _addr.code.length > 0);
    }
}
