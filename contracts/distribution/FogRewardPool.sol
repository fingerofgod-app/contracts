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

import "../interfaces/IWETH.sol";
import "../interfaces/IBasisAsset.sol";
import "../interfaces/IOracle.sol";

/**
 * @title FogRewardPool
 * @notice A staking reward pool where users deposit LP tokens to earn FOG.
 * @dev FOG rewards are distributed over time (rewardPerSecond) to stakers. When harvesting, users must pay a fee in native Sonic,
 * which is used for peg stabilization. In addition, this contract supports emergency withdrawal.
 */
contract FogRewardPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // Governance
    address public operator;

    // User info for stakers.
    struct UserInfo {
        uint256 amount; // LP tokens provided by the user.
        uint256 rewardDebt; // Reward debt; used for reward calculations.
    }

    // Pool info for each LP token.
    struct PoolInfo {
        IERC20 token; // LP token contract.
        uint256 allocPoint; // Allocation points for FOG distribution.
        uint256 lastRewardTime; // Last timestamp FOG distribution occurred.
        uint256 accFogPerShare; // Accumulated FOG per share (scaled by 1e18).
        bool isStarted; // True if pool reward distribution has started.
    }

    // FOG token and price oracle.
    address public fog;
    IOracle public fogOracle;
    uint256 public pegStabilityModuleFee = 2500; // 25% fee; set to 0 to disable.
    uint256 public minClaimThreshold = 1e16; // Minimum claim threshold: 0.01 FOG.
    address public pegStabilizationReserves; // Address to receive part of minted rewards (Peg Stabilization Reserves).

    // Wrapped Sonic instance for native Sonic conversion.
    IWETH public wrappedSonic = IWETH(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38);

    // Pool and user accounting.
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => uint256)) public unclaimedRewards;

    // Total allocation points across all pools.
    uint256 public totalAllocPoint = 0;

    // Mining schedule.
    uint256 public poolStartTime;
    uint256 public poolEndTime;
    uint256 public rewardPerSecond = 0.00009512938 ether;
    uint256 public runningTime = 730 days;

    /* ========== EVENTS ========== */

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event SonicPaid(address indexed user, uint256 amount);
    event UpdateRewardPerSecond(uint256 rewardPerSecond);

    /* ========== CONSTRUCTOR ========== */

    /**
     * @notice Constructs the FogRewardPool.
     * @param _fog Address of the FOG token.
     * @param _pegStabilizationReserves Address for the Peg Stabilization Reserves.
     * @param _poolStartTime Timestamp for when FOG mining begins.
     */
    constructor(address _fog, address _pegStabilizationReserves, uint256 _poolStartTime) {
        require(block.timestamp < _poolStartTime, "Pool cannot start in the past");
        require(_fog != address(0), "Invalid FOG address");
        require(_pegStabilizationReserves != address(0), "Invalid pegStabilizationReserves address");

        fog = _fog;
        pegStabilizationReserves = _pegStabilizationReserves;

        poolStartTime = _poolStartTime;
        poolEndTime = _poolStartTime + runningTime;
        operator = msg.sender;
    }

    /**
     * @notice Allow the contract to receive native Sonic.
     */
    receive() external payable {}

    /* ========== MODIFIERS ========== */

    /**
     * @dev Throws if called by any account other than the operator.
     */
    modifier onlyOperator() {
        require(operator == msg.sender, "FogRewardPool: caller is not the operator");
        _;
    }

    /* ========== POOL MANAGEMENT ========== */

    /**
     * @notice Returns the number of pools.
     * @return Number of pools.
     */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @dev Ensures no duplicate pool exists for the same LP token.
     * @param _token LP token address.
     */
    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "FogRewardPool: existing pool?");
        }
    }

    /**
     * @notice Adds a new LP pool.
     * @param _allocPoint Allocation points for FOG distribution.
     * @param _token LP token address.
     * @param _lastRewardTime Custom last reward timestamp; if zero, it defaults to poolStartTime or current time.
     */
    function add(uint256 _allocPoint, IERC20 _token, uint256 _lastRewardTime) public onlyOperator {
        checkPoolDuplicate(_token);
        massUpdatePools();
        if (block.timestamp < poolStartTime) {
            _lastRewardTime = (_lastRewardTime == 0 || _lastRewardTime < poolStartTime) ? poolStartTime : _lastRewardTime;
        } else {
            _lastRewardTime = (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) ? block.timestamp : _lastRewardTime;
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) || (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({token: _token, allocPoint: _allocPoint, lastRewardTime: _lastRewardTime, accFogPerShare: 0, isStarted: _isStarted}));
        if (_isStarted) {
            totalAllocPoint += _allocPoint;
        }
    }

    /**
     * @notice Updates allocation points for an existing pool.
     * @param _pid Pool id.
     * @param _allocPoint New allocation points.
     */
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        }
        pool.allocPoint = _allocPoint;
    }

    /**
     * @notice Bulk updates allocation points for multiple pools.
     * @param _pids Array of pool ids.
     * @param _allocPoints Array of new allocation points.
     */
    function bulkSet(uint256[] calldata _pids, uint256[] calldata _allocPoints) external onlyOperator {
        require(_pids.length == _allocPoints.length, "FogRewardPool: invalid length");
        for (uint256 i = 0; i < _pids.length; i++) {
            set(_pids[i], _allocPoints[i]);
        }
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Returns the pending FOG rewards for a user in a pool.
     * @param _pid Pool id.
     * @param _user User address.
     * @return Pending FOG reward.
     */
    function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFogPerShare = pool.accFogPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 _fogReward = (elapsed * rewardPerSecond * pool.allocPoint) / totalAllocPoint;
            accFogPerShare += (_fogReward * 1e18) / tokenSupply;
        }
        return unclaimedRewards[_pid][_user] + ((user.amount * accFogPerShare) / 1e18) - user.rewardDebt;
    }

    /**
     * @notice Returns the total pending FOG rewards for a user across all pools.
     * @param _user User address.
     * @return Total pending rewards.
     */
    function pendingAllRewards(address _user) public view returns (uint256) {
        uint256 length = poolInfo.length;
        uint256 totalPending;
        for (uint256 pid = 0; pid < length; ++pid) {
            totalPending += pendingReward(pid, _user);
        }
        return totalPending;
    }

    /**
     * @notice Gets the FOG price in Sonic by querying the fogOracle.
     * @return FOG price in Sonic.
     */
    function getFogPriceInSonic() public view returns (uint256) {
        return fogOracle.twap(address(fog), 1e18);
    }

    /**
     * @notice Returns the native Sonic fee required to harvest pending rewards for a pool.
     * @param _pid Pool id.
     * @param _user User address.
     * @return Fee in native Sonic.
     */
    function getBribingSonicToHarvest(uint256 _pid, address _user) external view returns (uint256) {
        uint256 pending = pendingReward(_pid, _user);
        return (getFogPriceInSonic() * pending * pegStabilityModuleFee) / 1e22;
    }

    /**
     * @notice Returns the total native Sonic fee to harvest all pending rewards for a user.
     * @param _user User address.
     * @return Total fee in native Sonic.
     */
    function getBribingSonicToHarvestAll(address _user) external view returns (uint256) {
        uint256 pending = pendingAllRewards(_user);
        return (getFogPriceInSonic() * pending * pegStabilityModuleFee) / 1e22;
    }

    /* ========== UPDATE FUNCTIONS ========== */

    /**
     * @notice Updates reward variables for all pools.
     */
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * @notice Updates reward variables for a specific pool.
     * @param _pid Pool id.
     */
    function updatePool(uint256 _pid) private {
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
            totalAllocPoint += pool.allocPoint;
        }
        if (totalAllocPoint > 0) {
            uint256 elapsed = block.timestamp - pool.lastRewardTime;
            uint256 _fogReward = (elapsed * rewardPerSecond * pool.allocPoint) / totalAllocPoint;
            pool.accFogPerShare += (_fogReward * 1e18) / tokenSupply;
        }
        pool.lastRewardTime = block.timestamp;
    }

    /* ========== USER FUNCTIONS ========== */

    /**
     * @notice Deposits LP tokens into a pool.
     * @param _pid Pool id.
     * @param _amount Amount of LP tokens to deposit.
     */
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = (user.amount * pool.accFogPerShare) / 1e18 - user.rewardDebt;
            if (_pending > 0) {
                unclaimedRewards[_pid][_sender] += _pending;
            }
        }
        if (_amount > 0) {
            IERC20 _lpToken = IERC20(pool.token);
            uint256 _before = _lpToken.balanceOf(address(this));
            _lpToken.safeTransferFrom(_sender, address(this), _amount);
            _amount = _lpToken.balanceOf(address(this)) - _before; // adjust for deflationary tokens
            if (_amount > 0) {
                user.amount += _amount;
            }
        }
        user.rewardDebt = (user.amount * pool.accFogPerShare) / 1e18;
        emit Deposit(_sender, _pid, _amount);
    }

    /**
     * @notice Withdraws LP tokens from a pool.
     * @param _pid Pool id.
     * @param _amount Amount of LP tokens to withdraw.
     */
    function withdraw(uint256 _pid, uint256 _amount) public payable nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: insufficient balance");
        updatePool(_pid);
        uint256 pending = (user.amount * pool.accFogPerShare) / 1e18 - user.rewardDebt;
        if (pending > 0) {
            unclaimedRewards[_pid][_sender] += pending;
        }
        if (_amount > 0) {
            user.amount -= _amount;
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = (user.amount * pool.accFogPerShare) / 1e18;
        emit Withdraw(_sender, _pid, _amount);
    }

    /**
     * @notice Harvests pending FOG rewards for a specific pool.
     * Users must pay a bribe fee in native Sonic, converted to Wrapped Sonic.
     * @param _pid Pool id.
     */
    function harvest(uint256 _pid) public payable nonReentrant {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);

        uint256 _pending = (user.amount * pool.accFogPerShare) / 1e18 - user.rewardDebt;
        uint256 _rewardsToClaim = _pending + unclaimedRewards[_pid][_sender];

        require(_rewardsToClaim >= minClaimThreshold, "Claim amount below minimum threshold");

        if (_rewardsToClaim > 0) {
            unclaimedRewards[_pid][_sender] = 0;

            uint256 amountSonicToPay = 0;
            if (pegStabilityModuleFee > 0) {
                amountSonicToPay = (getFogPriceInSonic() * _rewardsToClaim * pegStabilityModuleFee) / 1e22;
                require(msg.value >= amountSonicToPay, "insufficient sonic for PSM cost");
                emit SonicPaid(_sender, amountSonicToPay);
            } else {
                require(msg.value == 0, "Invalid msg.value");
            }

            safeFogTransfer(_sender, _rewardsToClaim);
            emit RewardPaid(_sender, _rewardsToClaim);

            if (pegStabilityModuleFee > 0 && msg.value > amountSonicToPay) {
                uint256 refundAmount = msg.value - amountSonicToPay;
                (bool success, ) = _sender.call{value: refundAmount}("");
                require(success, "Refund failed");
            }
        }
        user.rewardDebt = (user.amount * pool.accFogPerShare) / 1e18;
    }

    /**
     * @notice Harvests pending FOG rewards from all pools.
     */
    function harvestAll() public payable nonReentrant {
        address _sender = msg.sender;
        uint256 length = poolInfo.length;
        uint256 totalUserRewardsToClaim = 0;

        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][_sender];

            updatePool(pid);

            uint256 _pending = (user.amount * pool.accFogPerShare) / 1e18 - user.rewardDebt;
            uint256 _rewardsToClaim = _pending + unclaimedRewards[pid][_sender];

            if (_rewardsToClaim > 0) {
                unclaimedRewards[pid][_sender] = 0;
                totalUserRewardsToClaim += _rewardsToClaim;
            }
            user.rewardDebt = (user.amount * pool.accFogPerShare) / 1e18;
        }

        require(totalUserRewardsToClaim >= minClaimThreshold, "Claim amount below minimum threshold");

        if (totalUserRewardsToClaim > 0) {
            uint256 amountSonicToPay = 0;
            if (pegStabilityModuleFee > 0) {
                amountSonicToPay = (getFogPriceInSonic() * totalUserRewardsToClaim * pegStabilityModuleFee) / 1e22;
                require(msg.value >= amountSonicToPay, "insufficient sonic for PSM cost");
                emit SonicPaid(_sender, amountSonicToPay);
            } else {
                require(msg.value == 0, "Invalid msg.value");
            }

            safeFogTransfer(_sender, totalUserRewardsToClaim);
            emit RewardPaid(_sender, totalUserRewardsToClaim);

            if (pegStabilityModuleFee > 0 && msg.value > amountSonicToPay) {
                uint256 refundAmount = msg.value - amountSonicToPay;
                (bool success, ) = _sender.call{value: refundAmount}("");
                require(success, "Refund failed");
            }
        }
    }

    /**
     * @notice Emergency withdrawal of LP tokens.
     * @param _pid Pool id.
     */
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        unclaimedRewards[_pid][msg.sender] = 0;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice Safely transfers FOG tokens to a recipient. Mints additional tokens if the contract balance is insufficient.
     * @param _to The recipient address.
     * @param _amount The amount of FOG to transfer.
     */
    function safeFogTransfer(address _to, uint256 _amount) internal {
        uint256 _fogBal = IERC20(fog).balanceOf(address(this));
        if (_fogBal < _amount) {
            IBasisAsset(fog).mint(address(this), _amount - _fogBal);
        }
        _fogBal = IERC20(fog).balanceOf(address(this));
        if (_fogBal > 0) {
            if (_amount > _fogBal) {
                IERC20(fog).safeTransfer(_to, _fogBal);
            } else {
                IERC20(fog).safeTransfer(_to, _amount);
            }
        }
    }

    /* ========== GOVERNANCE & ADMIN FUNCTIONS ========== */

    function setOperator(address _operator) external onlyOperator {
        require(_operator != address(0), "Invalid address");
        operator = _operator;
    }

    function setPegStabilizationReserves(address _pegStabilizationReserves) public onlyOperator {
        require(_pegStabilizationReserves != address(0), "Invalid address");
        pegStabilizationReserves = _pegStabilizationReserves;
    }

    function setPegStabilityModuleFee(uint256 _pegStabilityModuleFee) external onlyOperator {
        require(_pegStabilityModuleFee <= 5000, "Invalid fee"); // max 50%
        pegStabilityModuleFee = _pegStabilityModuleFee;
    }

    function setFogOracle(address _fogOracle) external onlyOperator {
        require(_fogOracle != address(0), "Invalid address");
        fogOracle = IOracle(_fogOracle);
    }

    function setMinClaimThreshold(uint256 _minClaimThreshold) external onlyOperator {
        require(_minClaimThreshold <= 1e18, "Invalid min claim threshold");
        minClaimThreshold = _minClaimThreshold;
    }

    function setWSonic(IWETH _wrappedSonic) external onlyOperator {
        require(address(_wrappedSonic) != address(0), "Invalid Wrapped Sonic address");
        wrappedSonic = _wrappedSonic;
    }

    function setRewardPerSecond(uint256 _rewardPerSecond) external onlyOperator {
        require(_rewardPerSecond <= 0.00019 ether, "Rate too high");
        massUpdatePools();
        rewardPerSecond = _rewardPerSecond;
        emit UpdateRewardPerSecond(_rewardPerSecond);
    }

    /**
     * @notice Allows the operator to recover unsupported tokens.
     * @param _token The token to recover.
     * @param amount The amount to recover.
     * @param _to The recipient address.
     */
    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address _to) external onlyOperator {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            require(_token != pool.token, "Token cannot be pool token");
        }
        _token.safeTransfer(_to, amount);
    }

    /**
     * @notice Collects all native Sonic held by this contract, wraps it into Wrapped Sonic, and transfers it to pegStabilizationReserves.
     */
    function collectSonic() external {
        require(address(wrappedSonic) != address(0), "wrappedSonic not set");
        uint256 amount = address(this).balance;
        require(amount > 0, "No Sonic balance to collect");
        wrappedSonic.deposit{value: amount}();
        IERC20(wrappedSonic).safeTransfer(pegStabilizationReserves, amount);
    }
}
