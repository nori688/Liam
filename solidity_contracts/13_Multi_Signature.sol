// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MultiSignature {
    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public requiredSignatures;
    uint256 public transactionCount;

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmations;

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequirementChanged(uint256 newRequired);
    event Submission(uint256 indexed transactionId);
    event Confirmation(address indexed sender, uint256 indexed transactionId);
    event Execution(uint256 indexed transactionId);
    event Revocation(address indexed sender, uint256 indexed transactionId);

    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not owner");
        _;
    }

    modifier transactionExists(uint256 _transactionId) {
        require(transactions[_transactionId].to != address(0), "Transaction does not exist");
        _;
    }

    modifier notExecuted(uint256 _transactionId) {
        require(!transactions[_transactionId].executed, "Transaction already executed");
        _;
    }

    modifier notConfirmed(uint256 _transactionId) {
        require(!confirmations[_transactionId][msg.sender], "Transaction already confirmed");
        _;
    }

    constructor(address[] memory _owners, uint256 _required) {
        require(_owners.length >= 1, "Owners required");
        require(_required >= 1 && _required <= _owners.length, "Invalid required number");
        
        for (uint256 i = 0; i < _owners.length; i++) {
            require(_owners[i] != address(0), "Invalid owner");
            require(!isOwner[_owners[i]], "Duplicate owner");
            
            isOwner[_owners[i]] = true;
            owners.push(_owners[i]);
        }
        
        requiredSignatures = _required;
    }

    function addOwner(address _owner) external onlyOwner {
        require(!isOwner[_owner], "Already owner");
        require(owners.length < 10, "Too many owners");
        
        isOwner[_owner] = true;
        owners.push(_owner);
        
        emit OwnerAdded(_owner);
    }

    function removeOwner(address _owner) external onlyOwner {
        require(isOwner[_owner], "Not owner");
        require(owners.length - 1 >= requiredSignatures, "Cannot remove owner");
        
        isOwner[_owner] = false;
        
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == _owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        
        emit OwnerRemoved(_owner);
    }

    function changeRequirement(uint256 _required) external onlyOwner {
        require(_required >= 1 && _required <= owners.length, "Invalid required number");
        requiredSignatures = _required;
        emit RequirementChanged(_required);
    }

    function submitTransaction(
        address _to,
        uint256 _value,
        bytes memory _data
    ) external onlyOwner returns (uint256) {
        uint256 transactionId = transactionCount;
        transactions[transactionId] = Transaction({
            to: _to,
            value: _value,
            data: _data,
            executed: false,
            confirmations: 0
        });
        
        transactionCount++;
        emit Submission(transactionId);
        return transactionId;
    }

    function confirmTransaction(uint256 _transactionId)
        external
        onlyOwner
        transactionExists(_transactionId)
        notExecuted(_transactionId)
        notConfirmed(_transactionId)
    {
        confirmations[_transactionId][msg.sender] = true;
        transactions[_transactionId].confirmations++;
        emit Confirmation(msg.sender, _transactionId);
    }

    function executeTransaction(uint256 _transactionId)
        external
        onlyOwner
        transactionExists(_transactionId)
        notExecuted(_transactionId)
    {
        require(
            transactions[_transactionId].confirmations >= requiredSignatures,
            "Not enough confirmations"
        );
        
        Transaction storage txn = transactions[_transactionId];
        txn.executed = true;
        
        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        require(success, "Transaction execution failed");
        
        emit Execution(_transactionId);
    }

    function revokeConfirmation(uint256 _transactionId)
        external
        onlyOwner
        transactionExists(_transactionId)
        notExecuted(_transactionId)
    {
        require(confirmations[_transactionId][msg.sender], "Not confirmed");
        
        confirmations[_transactionId][msg.sender] = false;
        transactions[_transactionId].confirmations--;
        
        emit Revocation(msg.sender, _transactionId);
    }

    function isConfirmed(uint256 _transactionId) external view returns (bool) {
        return transactions[_transactionId].confirmations >= requiredSignatures;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getTransactionCount() external view returns (uint256) {
        return transactionCount;
    }
}
