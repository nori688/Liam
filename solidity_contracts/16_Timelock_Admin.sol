// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TimelockAdmin {
    address public admin;
    address public pendingAdmin;
    uint256 public delay;
    uint256 public gracePeriod;
    
    mapping(bytes32 => bool) public queuedTransactions;
    
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        uint256 executeTime;
        bool executed;
    }
    
    mapping(bytes32 => Transaction) public transactions;

    event NewAdmin(address indexed newAdmin);
    event NewDelay(uint256 newDelay);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 executeTime);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint256 value, bytes data);
    event CancelTransaction(bytes32 indexed txHash);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    modifier onlyPendingAdmin() {
        require(msg.sender == pendingAdmin, "Only pending admin");
        _;
    }

    constructor(uint256 _delay) {
        admin = msg.sender;
        delay = _delay;
        gracePeriod = 14 days;
    }

    function setDelay(uint256 _delay) external onlyAdmin {
        require(_delay >= 2 days, "Delay must be at least 2 days");
        delay = _delay;
        emit NewDelay(_delay);
    }

    function acceptAdmin() external onlyPendingAdmin {
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(admin);
    }

    function setPendingAdmin(address _pendingAdmin) external onlyAdmin {
        pendingAdmin = _pendingAdmin;
    }

    function queueTransaction(
        address _target,
        uint256 _value,
        bytes memory _data,
        uint256 _eta
    ) external onlyAdmin returns (bytes32) {
        require(_eta >= block.timestamp + delay, "Estimated execution time must satisfy delay");
        require(_eta <= block.timestamp + delay + gracePeriod, "Estimated execution time exceeds grace period");
        
        bytes32 txHash = keccak256(abi.encode(_target, _value, _data, _eta));
        queuedTransactions[txHash] = true;
        
        transactions[txHash] = Transaction({
            target: _target,
            value: _value,
            data: _data,
            executeTime: _eta,
            executed: false
        });
        
        emit QueueTransaction(txHash, _target, _value, _data, _eta);
        return txHash;
    }

    function executeTransaction(
        address _target,
        uint256 _value,
        bytes memory _data,
        uint256 _eta
    ) external onlyAdmin payable returns (bytes memory) {
        bytes32 txHash = keccak256(abi.encode(_target, _value, _data, _eta));
        
        require(queuedTransactions[txHash], "Transaction not queued");
        require(block.timestamp >= _eta, "Transaction hasn't surpassed time lock");
        require(block.timestamp <= _eta + gracePeriod, "Transaction is stale");
        require(!transactions[txHash].executed, "Transaction already executed");
        
        transactions[txHash].executed = true;
        queuedTransactions[txHash] = false;
        
        (bool success, bytes memory returnData) = _target.call{value: _value}(_data);
        require(success, "Transaction execution reverted");
        
        emit ExecuteTransaction(txHash, _target, _value, _data);
        return returnData;
    }

    function cancelTransaction(
        address _target,
        uint256 _value,
        bytes memory _data,
        uint256 _eta
    ) external onlyAdmin {
        bytes32 txHash = keccak256(abi.encode(_target, _value, _data, _eta));
        
        require(queuedTransactions[txHash], "Transaction not queued");
        require(!transactions[txHash].executed, "Transaction already executed");
        
        queuedTransactions[txHash] = false;
        
        emit CancelTransaction(txHash);
    }

    function getTransactionHash(
        address _target,
        uint256 _value,
        bytes memory _data,
        uint256 _eta
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(_target, _value, _data, _eta));
    }

    function isTransactionQueued(bytes32 _txHash) external view returns (bool) {
        return queuedTransactions[_txHash];
    }

    function isTransactionExecuted(bytes32 _txHash) external view returns (bool) {
        return transactions[_txHash].executed;
    }
}
