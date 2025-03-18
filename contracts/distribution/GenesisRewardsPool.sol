// SPDX-License-Identifier: MIT

/*
 *  This contract is open source under the MIT License.
 *  Snake Finance licensing claims? We love you, but we’re forging our own path.
 *  Feel free to copy, modify, or build upon this code.

 ########:'####:'##::: ##::'######:::'########:'########::::::'#######::'########:::::'######::::'#######::'########::
 ##.....::. ##:: ###:: ##:'##... ##:: ##.....:: ##.... ##::::'##.... ##: ##.....:::::'##... ##::'##.... ##: ##.... ##:
 ##:::::::: ##:: ####: ##: ##:::..::: ##::::::: ##:::: ##:::: ##:::: ##: ##:::::::::: ##:::..::: ##:::: ##: ##:::: ##:
 ######:::: ##:: ## ## ##: ##::'####: ######::: ########::::: ##:::: ##: ######:::::: ##::'####: ##:::: ##: ##:::: ##:
 ##...::::: ##:: ##. ####: ##::: ##:: ##...:::: ##.. ##:::::: ##:::: ##: ##...::::::: ##::: ##:: ##:::: ##: ##:::: ##:
 ##:::::::: ##:: ##:. ###: ##::: ##:: ##::::::: ##::. ##::::: ##:::: ##: ##:::::::::: ##::: ##:: ##:::: ##: ##:::: ##:
 ##:::::::'####: ##::. ##:. ######::: ########: ##:::. ##::::. #######:: ##::::::::::. ######:::. #######:: ########::
..::::::::....::..::::..:::......::::........::..:::::..::::::.......:::..::::::::::::......:::::.......:::........:::
*/

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Note that this pool has no minter key.
contract GenesisRewardsPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. fHOGs to distribute in the pool.
        uint256 lastRewardTime; // Last time that fHOGs distribution occurred.
        uint256 accRewardPerShare; // Accumulated fHOGs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IERC20 public fogHOG;
    IERC20 public fogSNAKE;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 private _totalAllocPoint;

    // The time when fogHOG mining starts.
    uint256 public poolStartTime;
    uint256 public poolEndTime;
    uint256 public poolRewardDuration;

    uint256 public totalFHogReward;
    uint256 public rewardPerSecond;

    uint256 private constant REWARD_RATE_DENOMINATION = 10000;
    uint256 public constant REWARD_RATE_FSNAKE = 15000;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 fogHogAmt, uint256 fogSnakeAmt);

    constructor(address _fogHOG, address _fogSNAKE, uint256 _poolStartTime) {
        require(block.timestamp < _poolStartTime, "late");

        fogHOG = IERC20(_fogHOG);
        fogSNAKE = IERC20(_fogSNAKE);

        poolRewardDuration = 7 days;
        totalFHogReward = 70000 gwei; // 70K fogHOG (decimals 9)
        rewardPerSecond = totalFHogReward / poolRewardDuration; // e.g. 0.11574074074 fogHOG/second

        poolStartTime = _poolStartTime;
        poolEndTime = _poolStartTime + poolRewardDuration;

        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "GenesisRewardPool: caller is not the operator");
        _;
    }

    function reward() external view returns (address) {
        return address(fogHOG);
    }

    function multiRewardLength() external pure returns (uint256) {
        return 2;
    }

    function multiRewards() external view returns (address[] memory _rewards) {
        _rewards = new address[](2);
        _rewards[0] = address(fogHOG);
        _rewards[1] = address(fogSNAKE);
    }

    function totalAllocPoint() external view returns (uint256) {
        return _totalAllocPoint;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolInfo(uint256 _pid) external view returns (address _lp, uint256 _allocPoint) {
        PoolInfo memory pool = poolInfo[_pid];
        _lp = address(pool.token);
        _allocPoint = pool.allocPoint;
    }

    // HOG reward per second
    function getRewardPerSecond() public view returns (uint256) {
        return (block.timestamp <= poolStartTime || block.timestamp > poolEndTime) ? 0 : rewardPerSecond;
    }

    function getMultiRewardPerSecond() external view returns (uint256[] memory _rewardPerSecondArr) {
        _rewardPerSecondArr = new uint256[](2);
        _rewardPerSecondArr[0] = getRewardPerSecond();
        _rewardPerSecondArr[1] = _rewardPerSecondArr[0] * REWARD_RATE_FSNAKE / REWARD_RATE_DENOMINATION;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "rewardPool: existing pool?");
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _token, uint256 _lastRewardTime) public onlyOperator {
        checkPoolDuplicate(_token);
        massUpdatePools();
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime < poolStartTime) {
                _lastRewardTime = poolStartTime;
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({token: _token, allocPoint: _allocPoint, lastRewardTime: _lastRewardTime, accRewardPerShare: 0, isStarted: _isStarted}));
        if (_isStarted) {
            _totalAllocPoint += _allocPoint;
        }
    }

    // Update the given pool's fogHOG allocation point. Can only be called by the owner.
    function setPoolAllocation(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            _totalAllocPoint = _totalAllocPoint - pool.allocPoint + _allocPoint;
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _fromTime to _toTime.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_toTime <= poolStartTime || _fromTime >= poolEndTime) return 0;
        if (_toTime > poolEndTime) _toTime = poolEndTime;
        if (_fromTime < poolStartTime) _fromTime = poolStartTime;
        return (_toTime - _fromTime) * rewardPerSecond;
    }

    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _fogHogReward = _generatedReward * pool.allocPoint / _totalAllocPoint;
            accRewardPerShare += (_fogHogReward * 1e18 / tokenSupply);
        }
        return (user.amount * accRewardPerShare / 1e18) - user.rewardDebt;
    }

    function pendingMultiRewards(uint256 _pid, address _user) public view returns (uint256[] memory _pendingMultiRewardArr) {
        uint256 _fogHogReward = pendingReward(_pid, _user);
        _pendingMultiRewardArr = new uint256[](2);
        _pendingMultiRewardArr[0] = _fogHogReward;
        _pendingMultiRewardArr[1] = _fogHogReward * REWARD_RATE_FSNAKE / REWARD_RATE_DENOMINATION;
    }

    function pendingAllRewards(address _user) public view returns (uint256 _total) {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _total = _total + pendingReward(pid, _user);
        }
    }

    function pendingAllMultiRewards(address _user) external view returns (uint256[] memory _totalMultiRewardArr) {
        uint256 _fogHogTotalReward = pendingAllRewards(_user);
        _totalMultiRewardArr = new uint256[](2);
        _totalMultiRewardArr[0] = _fogHogTotalReward;
        _totalMultiRewardArr[1] = _fogHogTotalReward * REWARD_RATE_FSNAKE / REWARD_RATE_DENOMINATION;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            _totalAllocPoint += pool.allocPoint;
        }
        if (_totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _fogHogReward = (_generatedReward * pool.allocPoint) / _totalAllocPoint;
            pool.accRewardPerShare += (_fogHogReward * 1e18 / tokenSupply);
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = (user.amount * pool.accRewardPerShare / 1e18) - user.rewardDebt;
            if (_pending > 0) {
                _claimReward(msg.sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
        }
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e18;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        _withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function _withdraw(address _account, uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = (user.amount * pool.accRewardPerShare / 1e18) - user.rewardDebt;
        if (_pending > 0) {
            _claimReward(_account, _pending);
        }
        if (_amount > 0) {
            user.amount -= _amount;
            pool.token.safeTransfer(_account, _amount);
        }
        user.rewardDebt = user.amount * pool.accRewardPerShare / 1e18;
        emit Withdraw(_account, _pid, _amount);
    }

    function withdrawAll(uint256 _pid) external nonReentrant {
        _withdraw(msg.sender, _pid, userInfo[_pid][msg.sender].amount);
    }

    function harvestAllRewards() external nonReentrant {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (userInfo[pid][msg.sender].amount > 0) {
                _withdraw(msg.sender, pid, 0);
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    function _claimReward(address _account, uint256 _fogHogAmt) internal {
        uint256 _fogSnakeAmt = _fogHogAmt * REWARD_RATE_FSNAKE / REWARD_RATE_DENOMINATION;
        _safeTokenTransfer(fogHOG, _account, _fogHogAmt);
        _safeTokenTransfer(fogSNAKE, _account, _fogSnakeAmt);
        emit RewardPaid(_account, _fogHogAmt, _fogSnakeAmt);
    }

    // Safe fogHOG transfer function, just in case if rounding error causes pool to not have enough fHOGs.
    function _safeTokenTransfer(IERC20 _token, address _to, uint256 _amount) internal {
        uint256 _tokenBal = _token.balanceOf(address(this));
        if (_tokenBal > 0) {
            if (_amount > _tokenBal) {
                _token.safeTransfer(_to, _tokenBal);
            } else {
                _token.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 30 days) {
            // do not allow to drain token if less than 30 days after farming ends.
            require(_token != fogSNAKE && _token != fogHOG, "reward");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "!pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
