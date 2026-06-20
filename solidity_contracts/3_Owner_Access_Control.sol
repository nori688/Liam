// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract OwnerControl {
    address public owner;
    mapping(address => bool) public authorizedUsers;
    uint256 public importantValue;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event UserAuthorized(address indexed user, bool status);
    event ValueUpdated(uint256 newValue);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedUsers[msg.sender], "Not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedUsers[msg.sender] = true;
    }

    // Только владелец может передать права
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // Только владелец может авторизовать пользователей
    function authorizeUser(address _user, bool _status) external onlyOwner {
        authorizedUsers[_user] = _status;
        emit UserAuthorized(_user, _status);
    }

    // Важная функция - только для авторизованных
    function updateImportantValue(uint256 _newValue) external onlyAuthorized {
        importantValue = _newValue;
        emit ValueUpdated(_newValue);
    }

    // Критическая функция - только для владельца
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}
