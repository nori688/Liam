// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract SafeExternalCalls {
    mapping(address => uint256) public balances;
    
    event ExternalCallSuccess(address indexed target, bytes data);
    event ExternalCallFailed(address indexed target, bytes data);

    // Небезопасный внешний вызов
    function unsafeExternalCall(address _target, bytes memory _data) external {
        (bool success, ) = _target.call(_data);
        // Нет проверки success!
    }

    // Безопасный внешний вызов с проверкой
    function safeExternalCall(address _target, bytes memory _data) external returns (bool) {
        require(_target != address(0), "Invalid target address");
        
        (bool success, bytes memory returnData) = _target.call(_data);
        
        require(success, "External call failed");
        
        // Проверяем возвращаемое значение если есть
        if (returnData.length > 0) {
            require(abi.decode(returnData, (bool)), "Operation returned false");
        }
        
        emit ExternalCallSuccess(_target, _data);
        return true;
    }

    // Внешний вызов с ограничением газа
    function safeExternalCallWithGasLimit(
        address _target, 
        bytes memory _data, 
        uint256 _gasLimit
    ) external returns (bool, bytes memory) {
        require(_target != address(0), "Invalid target address");
        require(_gasLimit > 0, "Gas limit must be positive");
        
        (bool success, bytes memory returnData) = _target.call{gas: _gasLimit}(_data);
        
        require(success, "External call failed");
        
        emit ExternalCallSuccess(_target, _data);
        return (success, returnData);
    }

    // Делегат вызов (delegatecall) - ОПАСНО, использовать с осторожностью
    function safeDelegateCall(address _target, bytes memory _data) external returns (bool) {
        require(_target != address(0), "Invalid target address");
        
        (bool success, bytes memory returnData) = _target.delegatecall(_data);
        
        require(success, "Delegate call failed");
        
        if (returnData.length > 0) {
            require(abi.decode(returnData, (bool)), "Operation returned false");
        }
        
        return true;
    }

    // Статический вызов (не изменяет состояние)
    function safeStaticCall(address _target, bytes memory _data) 
        external 
        view 
        returns (bytes memory) 
    {
        require(_target != address(0), "Invalid target address");
        
        (bool success, bytes memory returnData) = _target.staticcall(_data);
        
        require(success, "Static call failed");
        
        return returnData;
    }

    // Проверка контракта на существование
    function isContract(address _addr) external view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    // Безопасный перевод ETH с проверкой
    function safeTransferETH(address payable _to, uint256 _amount) external {
        require(_to != address(0), "Invalid recipient");
        require(address(this).balance >= _amount, "Insufficient balance");
        
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "ETH transfer failed");
    }

    // Безопасный вызов с try-catch (Solidity 0.8+)
    function tryExternalCall(address _target, bytes memory _data) 
        external 
        returns (bool success, bytes memory returnData) 
    {
        try this.externalCallWrapper(_target, _data) returns (bool _success, bytes memory _returnData) {
            success = _success;
            returnData = _returnData;
        } catch {
            success = false;
            returnData = "";
        }
    }

    function externalCallWrapper(address _target, bytes memory _data) 
        external 
        returns (bool success, bytes memory returnData) 
    {
        return _target.call(_data);
    }
}
