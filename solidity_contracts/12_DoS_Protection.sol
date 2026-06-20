// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract DoSProtection {
    mapping(address => uint256) public balances;
    address[] public users;
    mapping(address => bool) public isUser;
    
    uint256 public constant MAX_USERS = 100;
    uint256 public constant MAX_GAS_PER_USER = 100000;
    bool public paused;

    // Уязвимая функция - DoS через массив
    function vulnerableDistribute() external {
        for (uint256 i = 0; i < users.length; i++) {
            (bool success, ) = payable(users[i]).call{value: 1 ether}("");
            require(success, "Transfer failed");
        }
    }

    // Защита 1: Ограничение количества пользователей
    function addUser(address _user) external {
        require(!isUser[_user], "User already exists");
        require(users.length < MAX_USERS, "Max users reached");
        
        users.push(_user);
        isUser[_user] = true;
    }

    // Защита 2: Пагинация (pull pattern вместо push)
    function distributePaginated(uint256 _startIndex, uint256 _endIndex) external {
        require(_endIndex > _startIndex, "Invalid range");
        require(_endIndex <= users.length, "Index out of bounds");
        require(_endIndex - _startIndex <= 50, "Too many users per call");
        
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            (bool success, ) = payable(users[i]).call{value: 1 ether}("");
            require(success, "Transfer failed");
        }
    }

    // Защита 3: Pull pattern - пользователи сами забирают
    mapping(address => uint256) public pendingWithdrawals;

    function depositToUser(address _user) external payable {
        pendingWithdrawals[_user] += msg.value;
    }

    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        
        pendingWithdrawals[msg.sender] = 0;
        
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    // Защита 4: Ограничение газа на операцию
    function distributeWithGasLimit() external {
        for (uint256 i = 0; i < users.length; i++) {
            (bool success, ) = payable(users[i]).call{gas: MAX_GAS_PER_USER, value: 1 ether}("");
            if (!success) {
                // Продолжаем даже если один перевод не удался
                continue;
            }
        }
    }

    // Защита 5: Circuit breaker
    function pauseContract() external {
        paused = true;
    }

    function unpauseContract() external {
        paused = false;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    function safeOperation() external whenNotPaused {
        // Операция только если не пауза
    }

    // Защита 6: Проверка на revert внешнего контракта
    function safeExternalCall(address _target, bytes memory _data) external {
        require(_target != address(0), "Invalid target");
        
        // Ограничиваем газ для внешнего вызова
        (bool success, ) = _target.call{gas: 50000}(_data);
        
        if (!success) {
            // Логируем ошибку, но не revert
            revert("External call failed");
        }
    }

    // Защита 7: Reentrancy guard как защита от DoS
    bool private locked;

    modifier noReentrancy() {
        require(!locked, "Reentrancy detected");
        locked = true;
        _;
        locked = false;
    }

    function protectedFunction() external noReentrancy {
        // Защищенная функция
    }
}
