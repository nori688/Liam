// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ModifierAccessControl {
    address public owner;
    address public admin;
    mapping(address => bool) public moderators;
    mapping(address => bool) public users;
    mapping(address => uint256) public userLevels;

    // Базовые модификаторы доступа
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin || msg.sender == owner, "Only admin");
        _;
    }

    modifier onlyModerator() {
        require(moderators[msg.sender] || msg.sender == owner, "Only moderator");
        _;
    }

    modifier onlyUser() {
        require(users[msg.sender], "Only registered user");
        _;
    }

    // Комбинированные модификаторы
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == owner || msg.sender == admin, "Only owner or admin");
        _;
    }

    modifier minLevel(uint256 _level) {
        require(userLevels[msg.sender] >= _level, "Insufficient level");
        _;
    }

    // Модификатор с параметрами
    modifier validAddress(address _addr) {
        require(_addr != address(0), "Invalid address");
        _;
    }

    // Модификатор с проверкой времени
    modifier onlyDuringBusinessHours() {
        uint256 hour = (block.timestamp / 3600) % 24;
        require(hour >= 9 && hour < 18, "Outside business hours");
        _;
    }

    // Модификатор с проверкой баланса
    modifier hasMinimumBalance(uint256 _minBalance) {
        require(address(this).balance >= _minBalance, "Insufficient contract balance");
        _;
    }

    constructor() {
        owner = msg.sender;
        admin = msg.sender;
        moderators[msg.sender] = true;
        users[msg.sender] = true;
        userLevels[msg.sender] = 100;
    }

    // Примеры использования модификаторов

    function setAdmin(address _newAdmin) external onlyOwner validAddress(_newAdmin) {
        admin = _newAdmin;
    }

    function addModerator(address _moderator) external onlyAdmin validAddress(_moderator) {
        moderators[_moderator] = true;
    }

    function registerUser(address _user, uint256 _level) 
        external 
        onlyModerator 
        validAddress(_user) 
    {
        users[_user] = true;
        userLevels[_user] = _level;
    }

    function ownerFunction() external onlyOwner {
        // Только владелец
    }

    function adminFunction() external onlyAdmin {
        // Админ или владелец
    }

    function moderatorFunction() external onlyModerator {
        // Модератор или владелец
    }

    function userFunction() external onlyUser {
        // Зарегистрированный пользователь
    }

    function highLevelFunction() external onlyUser minLevel(50) {
        // Пользователь с уровнем >= 50
    }

    function businessHoursFunction() external onlyDuringBusinessHours {
        // Только в рабочее время
    }

    function payout(uint256 _amount) 
        external 
        onlyOwner 
        hasMinimumBalance(_amount) 
    {
        payable(owner).transfer(_amount);
    }
}
