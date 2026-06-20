// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract StakingContract {
    IERC20 public stakingToken;
    
    struct Stake {
        uint256 amount;
        uint256 timestamp;
        uint256 lastRewardUpdate;
    }
    
    mapping(address => Stake) public stakes;
    uint256 public rewardRate; // награда в секундах на 1 токен (в базовых единицах)
    uint256 public totalStaked;
    uint256 public constant MIN_STAKE_TIME = 1 days;
    
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event RewardClaimed(address indexed user, uint256 reward);

    constructor(address _tokenAddress, uint256 _rewardRate) {
        stakingToken = IERC20(_tokenAddress);
        rewardRate = _rewardRate;
    }

    function stake(uint256 _amount) external {
        require(_amount > 0, "Amount must be positive");
        require(stakingToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Если уже есть стейк, сначала начисляем награду
        if (stakes[msg.sender].amount > 0) {
            _updateReward(msg.sender);
        }
        
        stakes[msg.sender].amount += _amount;
        stakes[msg.sender].timestamp = block.timestamp;
        stakes[msg.sender].lastRewardUpdate = block.timestamp;
        totalStaked += _amount;
        
        emit Staked(msg.sender, _amount);
    }

    function unstake(uint256 _amount) external {
        require(stakes[msg.sender].amount >= _amount, "Insufficient staked amount");
        require(block.timestamp >= stakes[msg.sender].timestamp + MIN_STAKE_TIME, "Minimum stake time not reached");
        
        // Начисляем награду перед unstake
        _updateReward(msg.sender);
        
        stakes[msg.sender].amount -= _amount;
        totalStaked -= _amount;
        
        require(stakingToken.transfer(msg.sender, _amount), "Transfer failed");
        
        emit Unstaked(msg.sender, _amount, 0);
    }

    function claimReward() external {
        require(stakes[msg.sender].amount > 0, "No stake found");
        
        uint256 reward = _calculateReward(msg.sender);
        stakes[msg.sender].lastRewardUpdate = block.timestamp;
        
        require(reward > 0, "No reward to claim");
        
        // Предполагаем, что награда выплачивается в том же токене
        require(stakingToken.transfer(msg.sender, reward), "Reward transfer failed");
        
        emit RewardClaimed(msg.sender, reward);
    }

    function _updateReward(address _user) internal {
        stakes[_user].lastRewardUpdate = block.timestamp;
    }

    function _calculateReward(address _user) internal view returns (uint256) {
        Stake memory userStake = stakes[_user];
        uint256 timeElapsed = block.timestamp - userStake.lastRewardUpdate;
        
        // Награда = amount * rewardRate * timeElapsed
        return (userStake.amount * rewardRate * timeElapsed) / 1e18;
    }

    function getPendingReward(address _user) external view returns (uint256) {
        return _calculateReward(_user);
    }

    function getStakeInfo(address _user) external view returns (uint256 amount, uint256 timestamp, uint256 pendingReward) {
        Stake memory userStake = stakes[_user];
        return (userStake.amount, userStake.timestamp, _calculateReward(_user));
    }
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}
