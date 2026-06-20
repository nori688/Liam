// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract SafeERC20Transfer {
    IERC20 public token;

    event TokensTransferred(address indexed from, address indexed to, uint256 amount);
    event TransferFailed(address indexed from, address indexed to, uint256 amount);

    constructor(address _tokenAddress) {
        token = IERC20(_tokenAddress);
    }

    // Безопасный перевод токенов с проверками
    function safeTransfer(address _to, uint256 _amount) external {
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be positive");
        require(token.balanceOf(msg.sender) >= _amount, "Insufficient balance");
        
        // Проверка allowance если перевод от имени другого
        bool success;
        
        // Проверка возвращаемого значения
        (success, ) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, _to, _amount)
        );
        
        require(success, "Transfer call failed");
        
        // Дополнительная проверка баланса
        require(token.balanceOf(_to) >= _amount || _to == address(this), "Transfer verification failed");
        
        emit TokensTransferred(msg.sender, _to, _amount);
    }

    // Безопасный transferFrom
    function safeTransferFrom(address _from, address _to, uint256 _amount) external {
        require(_from != address(0), "Invalid sender");
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be positive");
        require(token.allowance(_from, msg.sender) >= _amount, "Insufficient allowance");
        require(token.balanceOf(_from) >= _amount, "Insufficient balance");
        
        bool success;
        (success, ) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, _from, _to, _amount)
        );
        
        require(success, "TransferFrom call failed");
        
        emit TokensTransferred(_from, _to, _amount);
    }

    // Проверка успешности вызова
    function _callOptionalReturn(address target, bytes memory data) private returns (bool) {
        (bool success, bytes memory returndata) = target.call(data);
        
        if (success) {
            if (returndata.length > 0) {
                require(abi.decode(returndata, (bool)), "Operation failed");
            }
        }
        
        return success;
    }
}
