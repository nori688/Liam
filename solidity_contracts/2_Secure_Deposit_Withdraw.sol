// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract SecureVault {
    mapping(address => uint256) public balances;
    uint256 public totalDeposits;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    // Checks-Effects-Interactions паттерн
    function deposit() external payable {
        // CHECKS
        require(msg.value > 0, "Amount must be greater than 0");
        
        // EFFECTS
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
        
        // INTERACTIONS (нет внешних вызовов для депозита)
        
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 _amount) external {
        // CHECKS
        require(_amount > 0, "Amount must be greater than 0");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        require(address(this).balance >= _amount, "Insufficient contract balance");
        
        // EFFECTS
        balances[msg.sender] -= _amount;
        totalDeposits -= _amount;
        
        // INTERACTIONS - только после изменения состояния
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit Withdraw(msg.sender, _amount);
    }

    function getBalance(address _user) external view returns (uint256) {
        return balances[_user];
    }

    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }
}
