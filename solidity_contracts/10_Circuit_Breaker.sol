// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract CircuitBreaker {
    bool public paused;
    bool public emergencyStop;
    address public pauser;
    address public owner;
    
    uint256 public dailyLimit;
    uint256 public dailyWithdrawn;
    uint256 public lastResetTime;
    
    mapping(address => bool) public exemptAddresses;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyStopActivated(address indexed by);
    event LimitReset(uint256 newLimit);

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "Contract is not paused");
        _;
    }

    modifier onlyPauser() {
        require(msg.sender == pauser || msg.sender == owner, "Not pauser");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier checkDailyLimit(uint256 _amount) {
        if (!exemptAddresses[msg.sender]) {
            _checkLimit(_amount);
        }
        _;
    }

    constructor(uint256 _dailyLimit) {
        owner = msg.sender;
        pauser = msg.sender;
        dailyLimit = _dailyLimit;
        lastResetTime = block.timestamp;
        exemptAddresses[msg.sender] = true;
    }

    function _checkLimit(uint256 _amount) internal {
        // Сброс суточного лимита если наступил новый день
        if (block.timestamp >= lastResetTime + 1 days) {
            dailyWithdrawn = 0;
            lastResetTime = block.timestamp;
        }
        
        require(dailyWithdrawn + _amount <= dailyLimit, "Daily limit exceeded");
        dailyWithdrawn += _amount;
    }

    // Пауза контракта
    function pause() external onlyPauser {
        paused = true;
        emit Paused(msg.sender);
    }

    // Снятие паузы
    function unpause() external onlyPauser {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // Экстренная остановка (только владелец)
    function emergencyStopContract() external onlyOwner {
        emergencyStop = true;
        paused = true;
        emit EmergencyStopActivated(msg.sender);
    }

    // Изменение суточного лимита
    function setDailyLimit(uint256 _newLimit) external onlyOwner {
        dailyLimit = _newLimit;
        emit LimitReset(_newLimit);
    }

    // Добавление адреса в исключения
    function setExemptAddress(address _addr, bool _status) external onlyOwner {
        exemptAddresses[_addr] = _status;
    }

    // Смена pauser
    function setPauser(address _newPauser) external onlyOwner {
        pauser = _newPauser;
    }

    // Пример функции с защитой
    function sensitiveOperation(uint256 _amount) 
        external 
        whenNotPaused 
        checkDailyLimit(_amount) 
    {
        // Логика операции
    }

    // Функция доступная только во время паузы (для восстановления)
    function recoveryOperation() external whenPaused onlyOwner {
        // Операции восстановления
    }
}
