// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract FrontRunningProtection {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public commitTimestamps;
    mapping(bytes32 => bool) public usedCommitments;
    
    uint256 public constant REVEAL_WINDOW = 10 minutes;
    uint256 public constant MIN_COMMIT_DELAY = 1 minutes;

    event Deposit(address indexed user, uint256 amount);
    event CommitCreated(address indexed user, bytes32 commitment);
    event CommitRevealed(address indexed user, uint256 amount);

    function deposit() external payable {
        require(msg.value > 0, "Amount must be positive");
        balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    // Уязвимая функция - подвержена front-running
    function vulnerableWithdraw(uint256 _amount) external {
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        balances[msg.sender] -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    // Защита с помощью commit-reveal схемы
    function createCommit(bytes32 _commitment) external {
        require(_commitment != bytes32(0), "Invalid commitment");
        require(!usedCommitments[_commitment], "Commitment already used");
        
        commitTimestamps[msg.sender] = block.timestamp;
        usedCommitments[_commitment] = true;
        
        emit CommitCreated(msg.sender, _commitment);
    }

    function revealCommit(
        uint256 _amount, 
        bytes32 _secret, 
        bytes32 _commitment
    ) external {
        require(usedCommitments[_commitment], "Commitment not found");
        require(
            block.timestamp >= commitTimestamps[msg.sender] + MIN_COMMIT_DELAY,
            "Too early to reveal"
        );
        require(
            block.timestamp <= commitTimestamps[msg.sender] + REVEAL_WINDOW,
            "Reveal window expired"
        );
        
        // Проверяем, что commitment соответствует данным
        bytes32 computedCommitment = keccak256(abi.encodePacked(msg.sender, _amount, _secret));
        require(computedCommitment == _commitment, "Invalid commitment");
        
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        balances[msg.sender] -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
        
        emit CommitRevealed(msg.sender, _amount);
    }

    // Защита с помощью deadline
    function withdrawWithDeadline(uint256 _amount, uint256 _deadline) external {
        require(block.timestamp <= _deadline, "Transaction expired");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        balances[msg.sender] -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    // Защита с помощью minimum gas price
    function withdrawWithGasLimit(uint256 _amount) external {
        require(tx.gasprice <= 50 gwei, "Gas price too high - possible front-running");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        balances[msg.sender] -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    // Создание commitment для commit-reveal
    function createCommitmentHash(uint256 _amount, bytes32 _secret) 
        external 
        view 
        returns (bytes32) 
    {
        return keccak256(abi.encodePacked(msg.sender, _amount, _secret));
    }
}
