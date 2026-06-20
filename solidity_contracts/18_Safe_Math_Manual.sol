// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SafeMathManual {
    // В Solidity 0.8+ переполнение автоматически проверяется
    // Но для образовательных целей реализуем вручную

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: division by zero");
        return a / b;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "SafeMath: modulo by zero");
        return a % b;
    }

    function pow(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b >= 0, "SafeMath: power with negative exponent");
        uint256 result = 1;
        for (uint256 i = 0; i < b; i++) {
            result = mul(result, a);
        }
        return result;
    }

    // Для работы с int256
    function add(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a + b;
        require((b >= 0 && c >= a) || (b < 0 && c < a), "SafeMath: addition overflow");
        return c;
    }

    function sub(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a - b;
        require((b >= 0 && c <= a) || (b < 0 && c > a), "SafeMath: subtraction overflow");
        return c;
    }

    function mul(int256 a, int256 b) internal pure returns (int256) {
        if (a == 0) return 0;
        require((a == -2**255 || b != -1) && (b == -2**255 || a != -1), "SafeMath: multiplication overflow");
        int256 c = a * b;
        require(c / a == b || (a == -1 && c == -2**255), "SafeMath: multiplication overflow");
        return c;
    }
}

contract SafeMathExample {
    using SafeMathManual for uint256;
    using SafeMathManual for int256;

    uint256 public totalSupply;
    mapping(address => uint256) public balances;

    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function mint(address _to, uint256 _amount) external {
        require(_to != address(0), "Invalid address");
        require(_amount > 0, "Amount must be positive");
        
        totalSupply = totalSupply.add(_amount);
        balances[_to] = balances[_to].add(_amount);
        
        emit Mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        require(_from != address(0), "Invalid address");
        require(_amount > 0, "Amount must be positive");
        require(balances[_from] >= _amount, "Insufficient balance");
        
        balances[_from] = balances[_from].sub(_amount);
        totalSupply = totalSupply.sub(_amount);
        
        emit Burn(_from, _amount);
    }

    function transfer(address _to, uint256 _amount) external {
        require(_to != address(0), "Invalid address");
        require(_amount > 0, "Amount must be positive");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        
        balances[msg.sender] = balances[msg.sender].sub(_amount);
        balances[_to] = balances[_to].add(_amount);
        
        emit Transfer(msg.sender, _to, _amount);
    }

    function calculatePercentage(uint256 _value, uint256 _percentage) external pure returns (uint256) {
        return _value.mul(_percentage).div(100);
    }

    function calculateInterest(uint256 _principal, uint256 _rate, uint256 _time) external pure returns (uint256) {
        return _principal.mul(_rate).mul(_time).div(10000).div(365 days);
    }
}
