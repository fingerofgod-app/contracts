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
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./utils/ContractGuard.sol";
import "./utils/ShareWrapper.sol";

import "./interfaces/IWETH.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IUFragments.sol";

/**
 * @title Boardroom
 * @notice Handles staking, reward allocation, and reward distribution for share holders.
 *         Supports multi-peg rewards by tracking separate snapshot histories for each peg token.
 * @dev This contract is upgradeable, reentrancy-protected, and inherits staking functionality
 *      from ShareWrapper. Reward claims support two options:
 *         Option 1: Immediate claim with a fixed reward sacrifice.
 *         Option 2: Direct claim that deducts a Sonic bribe fee.
 */
contract Boardroom is IBoardroom, ShareWrapper, ContractGuard, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /* ========== DATA STRUCTURES ========== */

    /// @notice Contains reward snapshot information for a member.
    struct Memberseat {
        uint256 lastSnapshotIndex; // Last snapshot index when rewards were updated.
        uint256 rewardEarned; // Accumulated rewards earned (pending claim).
    }

    /// @notice Represents a snapshot of the boardroom state for a peg token.
    struct BoardroomSnapshot {
        uint256 time; // Block number when the snapshot was taken.
        uint256 rewardReceived; // Total rewards received in this snapshot.
        uint256 rewardPerShare; // Cumulative reward per share (scaled by 1e18).
    }

    /// @notice Data structure for a pending withdrawal request.
    struct PendingWithdraw {
        uint256 amount; // Amount of staked shares pending withdrawal.
        uint256 unlockEpoch; // Epoch when withdrawal can be finalized.
    }

    /* ========== STATE VARIABLES ========== */

    ITreasury public treasury; // Treasury contract reference.
    address[] public pegTokens; // List of peg token addresses.

    // Mapping from member address to epoch timer start.
    mapping(address => uint256) public epochTimerStart;
    // Mapping: peg token => (member => Memberseat) for reward data.
    mapping(address => mapping(address => Memberseat)) public members;
    // Mapping: peg token => snapshot history.
    mapping(address => BoardroomSnapshot[]) public boardroomHistory;
    // Mapping: member address => pending withdrawal request.
    mapping(address => PendingWithdraw) public pendingWithdrawals;

    // Lockup parameters.
    uint256 public withdrawLockupEpochs; // Number of epochs to lock withdrawals.
    uint256 public rewardLockupEpochs; // Number of epochs to lock reward claims.
    uint256 public claimRewardsBurnEpochs; // Epoch after which unclaimed rewards are burned.

    // Claim Option 1: Immediate claim sacrifice percentage (in basis points, e.g., 3000 = 30%).
    uint256 public immediateClaimSacrificePercent;

    // Claim Option 2: Sonic bribe fee parameters.
    IWETH public wrappedSonic; // Wrapped Sonic contract.
    mapping(address => address) public tokenInSonicOracles; // Mapping: peg token => Sonic-price oracle.
    address public pegStabilizationReserves; // Peg Stability Reserves address.
    uint256 public pegStabilityModuleFee; // Fee in basis points for Sonic bribe.

    // Elastic (rebase) token parameters.
    mapping(address => bool) public pegTokenElastics; // True if token is elastic.
    mapping(address => uint256) public pegTokenFirstGonsPerFragments; // Initial conversion factor.
    mapping(address => uint256) public pegTokenCurrentGonsPerFragments; // Current conversion factor.

    // Loyalty configuration:
    // Example: If staked for 15+ days (assume 60 epochs) => 10% discount (1000 bp),
    // 45+ days (180 epochs) => 15% discount (1500 bp),
    // 100+ days (400 epochs) => 20% discount (2000 bp),
    // 365+ days (1460 epochs) => 30% discount (3000 bp).
    mapping(address => uint256) public epochDepositStart;
    uint256[] public loyaltyEpochs;
    uint256[] public loyaltyDiscounts;

    uint256 public totalCollectedSonic;

    /* =================== ADDED VARIABLES FOR PROXY COMPATIBILITY =================== */
    // Reserved for future variables added for proxy to work

    /* ========== EVENTS ========== */

    /// @notice Emitted when a member stakes shares.
    event Staked(address indexed user, uint256 amount);
    /// @notice Emitted when a member requests a pending withdrawal.
    event PendingWithdrawRequested(address indexed user, uint256 amount, uint256 unlockEpoch);
    /// @notice Emitted when a member cancels a pending withdrawal.
    event CancelPendingWithdraw(address indexed user, uint256 amount);
    /// @notice Emitted when a member finalizes a pending withdrawal.
    event PendingWithdrawFinalized(address indexed user, uint256 amount);
    /// @notice Emitted when a member claims rewards.
    event RewardPaid(address indexed token, address indexed user, uint256 reward);
    /// @notice Emitted when rewards are added to the boardroom snapshot.
    event RewardAdded(address indexed token, address indexed user, uint256 reward);
    /// @notice Emitted when a member sacrifices (burns) their reward.
    event RewardSacrificed(address indexed token, address indexed user, uint256 reward);
    /// @notice Emitted when native Sonic is used as a bribe.
    event SonicBribed(address indexed user, uint256 totalFee, uint256 discountedFee);
    /// @notice Emitted when a new peg token is added to the boardroom.
    event PegTokenAdded(address indexed token, bool isElastic);
    /// @notice Emitted when peg token elastic is enabled/disabled.
    event PegTokenSet(address indexed token, bool isElastic);
    /// @notice Emitted for each elastic peg token when its gonsPerFragment is synced.
    event SyncElastic(address indexed token, uint256 newGonsPerFragment);
    /// @notice Emitted for each sonic collected to Peg Stability Reserves.
    event SonicCollected(uint256 amount);

    /* ========== MODIFIERS ========== */

    /// @notice Restricts execution to the Treasury contract.
    modifier onlyTreasury() {
        require(address(treasury) == msg.sender, "Boardroom: caller is not the treasury");
        _;
    }

    /// @notice Ensures the member has a positive staked balance.
    modifier memberExists() {
        require(balanceOf(msg.sender) > 0, "Boardroom: The member does not exist");
        _;
    }

    /**
     * @notice Updates reward data for the specified member across all peg tokens.
     * @param _member The address of the member.
     */
    modifier updateReward(address _member) {
        if (_member != address(0)) {
            uint256 len = pegTokens.length;
            for (uint256 i = 0; i < len; ++i) {
                address token = pegTokens[i];
                // If token is elastic, sync its conversion factor.
                if (pegTokenElastics[token] && pegTokenCurrentGonsPerFragments[token] != IUFragments(token).gonsPerFragment()) {
                    _syncGonsPerFragment(token);
                }
                Memberseat memory seat = members[token][_member];
                seat.rewardEarned = _earnedOriginal(token, _member);
                seat.lastSnapshotIndex = latestSnapshotIndex(token);
                members[token][_member] = seat;
            }
        }
        _;
    }

    /* ========== GOVERNANCE FUNCTIONS ========== */

    /**
     * @notice Initializes the Boardroom contract.
     * @param _fHog Address of the first peg token (e.g., fogHOG).
     * @param _fSnake Address of the second peg token (e.g., fogSNAKE).
     * @param _fog Address of the share token (e.g., FOG).
     * @param _pegStabilizationReserves Address for the peg stabilization reserves.
     * @param _treasury Treasury contract address.
     */
    function initialize(address _fHog, address _fSnake, address _fog, address _pegStabilizationReserves, ITreasury _treasury) external initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);

        // Set share token.
        share = IERC20(_fog);
        pegStabilizationReserves = _pegStabilizationReserves;
        treasury = _treasury;

        // Configure peg tokens.
        pegTokens.push(_fHog);
        pegTokens.push(_fSnake);

        pegTokenElastics[_fHog] = true;
        pegTokenCurrentGonsPerFragments[_fHog] = pegTokenFirstGonsPerFragments[_fHog] = IUFragments(_fHog).gonsPerFragment();

        pegTokenElastics[_fSnake] = true;
        pegTokenCurrentGonsPerFragments[_fSnake] = pegTokenFirstGonsPerFragments[_fSnake] = IUFragments(_fSnake).gonsPerFragment();

        // Initialize snapshot history for each peg token.
        boardroomHistory[_fHog].push(BoardroomSnapshot({time: block.number, rewardReceived: 0, rewardPerShare: 0}));
        boardroomHistory[_fSnake].push(BoardroomSnapshot({time: block.number, rewardReceived: 0, rewardPerShare: 0}));

        // Set lockup parameters.
        withdrawLockupEpochs = 8; // 8 epochs lockup for withdrawal.
        rewardLockupEpochs = 2; // 2 epochs lockup for reward claim.
        claimRewardsBurnEpochs = 10; // Rewards unclaimed for 10 epochs will be burned.

        // Set default immediate claim sacrifice percentage to 34% (3400 basis points).
        immediateClaimSacrificePercent = 3400;
        // Set default peg stability module fee to 25% (2500 basis points).
        pegStabilityModuleFee = 2500;

        // Set default Wrapped Sonic.
        wrappedSonic = IWETH(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38);

        loyaltyEpochs = [60, 180, 400, 1460];
        loyaltyDiscounts = [1000, 1500, 2000, 3000];
    }

    /**
     * @notice Allows the contract to receive native Sonic.
     */
    receive() external payable {}

    /**
     * @notice Sets the lockup durations for withdrawals, reward claims, and reward burning.
     * @param _withdrawLockupEpochs Epochs to lock withdrawals.
     * @param _rewardLockupEpochs Epochs to lock reward claims.
     * @param _claimRewardsBurnEpochs Epoch after which unclaimed rewards are burned.
     */
    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs, uint256 _claimRewardsBurnEpochs) external onlyOwner {
        require(_rewardLockupEpochs <= 21 && _withdrawLockupEpochs <= 21 && _claimRewardsBurnEpochs <= 21, "lockupEpochs cannot exceed 1 week");
        require(_rewardLockupEpochs + 2 <= _claimRewardsBurnEpochs, "Need window to claim before burning rewards");
        require(_claimRewardsBurnEpochs >= 6, "At least 6 epochs required before rewards are burnt");
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
        claimRewardsBurnEpochs = _claimRewardsBurnEpochs;
    }

    /**
     * @notice Updates the immediate claim sacrifice percentage.
     * @param _percent New percentage in basis points (0-10000).
     */
    function setImmediateClaimSacrificePercent(uint256 _percent) external onlyOwner {
        require(_percent <= 10000, "Invalid percentage");
        immediateClaimSacrificePercent = _percent;
    }

    /**
     * @notice Sets the Wrapped Sonic contract.
     * @param _wrappedSonic Address of the Wrapped Sonic contract.
     */
    function setWSonic(IWETH _wrappedSonic) external onlyOwner {
        require(address(_wrappedSonic) != address(0), "Invalid Wrapped Sonic address");
        wrappedSonic = _wrappedSonic;
    }

    /**
     * @notice Sets the Sonic oracle for a peg token.
     * @param _pegToken Peg token address.
     * @param _oracle Oracle address that returns the token price in Sonic.
     */
    function setTokenInSonicOracle(address _pegToken, address _oracle) external onlyOwner {
        require(_pegToken != address(0) && _oracle != address(0), "Invalid address");
        tokenInSonicOracles[_pegToken] = _oracle;
    }

    /**
     * @notice Sets the peg stabilization reserves address.
     * @param _pegStabilizationReserves New peg stabilization reserves address.
     */
    function setPegStabilizationReserves(address _pegStabilizationReserves) external onlyOwner {
        require(_pegStabilizationReserves != address(0), "Invalid peg stabilization reserves address");
        pegStabilizationReserves = _pegStabilizationReserves;
    }

    /**
     * @notice Sets the peg stability module fee.
     * @param _fee New fee in basis points; must be between 500 (5%) and 5000 (50%).
     */
    function setPegStabilityModuleFee(uint256 _fee) external onlyOwner {
        require(_fee >= 500 && _fee <= 5000, "Boardroom: fee must be between 5% and 50%");
        pegStabilityModuleFee = _fee;
    }

    /**
     * @notice Adds a new peg token to the boardroom.
     * @param _token The peg token address to add.
     * @param _isElastic Whether the token is elastic (i.e., its supply can rebase).
     */
    function addPegToken(address _token, bool _isElastic) external onlyOwner {
        require(boardroomHistory[_token].length == 0, "Boardroom: boardroomHistory exists");
        require(IERC20(_token).totalSupply() > 0, "Boardroom: invalid token");
        uint256 len = pegTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            require(pegTokens[i] != _token, "Boardroom: existing token");
        }
        pegTokens.push(_token);
        boardroomHistory[_token].push(BoardroomSnapshot({time: block.number, rewardReceived: 0, rewardPerShare: 0}));
        if (_isElastic) {
            pegTokenElastics[_token] = true;
            uint256 _gonsPerFragment = IUFragments(_token).gonsPerFragment();
            require(_gonsPerFragment > 0, "Boardroom: invalid elastic supply token");
            pegTokenFirstGonsPerFragments[_token] = _gonsPerFragment;
            pegTokenCurrentGonsPerFragments[_token] = _gonsPerFragment;
        }
        emit PegTokenAdded(_token, _isElastic);
    }

    function setPegTokenElastic(address _token, bool _isElastic) external onlyOwner {
        pegTokenElastics[_token] = _isElastic;
        pegTokenFirstGonsPerFragments[_token] = pegTokenCurrentGonsPerFragments[_token] = (_isElastic) ? IUFragments(_token).gonsPerFragment() : 0;
        emit PegTokenSet(_token, _isElastic);
    }

    /**
     * @notice Sets the loyalty parameters.
     * @param _loyaltyEpochs Array of epoch thresholds for loyalty (in epochs).
     * @param _loyaltyDiscounts Array of corresponding loyalty discounts in basis points.
     * @dev The lengths of both arrays must be equal.
     */
    function setLoyaltyParameters(uint256[] calldata _loyaltyEpochs, uint256[] calldata _loyaltyDiscounts) external onlyOwner {
        require(_loyaltyEpochs.length == _loyaltyDiscounts.length, "Boardroom: array lengths must match");
        loyaltyEpochs = _loyaltyEpochs;
        loyaltyDiscounts = _loyaltyDiscounts;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Returns the latest snapshot index for a given peg token.
     * @param _token The peg token address.
     * @return The index of the latest snapshot.
     */
    function latestSnapshotIndex(address _token) public view returns (uint256) {
        return boardroomHistory[_token].length - 1;
    }

    /**
     * @notice Retrieves the latest snapshot for a given peg token.
     * @param _token The peg token address.
     * @return The latest BoardroomSnapshot.
     */
    function getLatestSnapshot(address _token) internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[_token][latestSnapshotIndex(_token)];
    }

    /**
     * @notice Retrieves the last snapshot index for a member and peg token.
     * @param _token The peg token address.
     * @param _member The member's address.
     * @return The snapshot index.
     */
    function getLastSnapshotIndexOf(address _token, address _member) public view returns (uint256) {
        return members[_token][_member].lastSnapshotIndex;
    }

    /**
     * @notice Retrieves the last snapshot for a member for a specific peg token.
     * @param _token The peg token address.
     * @param _member The member's address.
     * @return The BoardroomSnapshot at the member's last snapshot index.
     */
    function getLastSnapshotOf(address _token, address _member) internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[_token][getLastSnapshotIndexOf(_token, _member)];
    }

    /**
     * @notice Checks whether a member can claim rewards based on the lockup period.
     * @param member The member's address.
     * @return True if the member can claim rewards.
     */
    function canClaimReward(address member) external view returns (bool) {
        return epochTimerStart[member] + rewardLockupEpochs <= treasury.epoch();
    }

    /**
     * @notice Provides information on reward burning for a member.
     * @param member Member address.
     * @return _burned True if rewards will be burnt.
     * @return _burningEpoch Epoch at which rewards are burnt.
     */
    function burningRewardsInfo(address member) external view returns (bool _burned, uint256 _burningEpoch) {
        if (balanceOf(member) > 0) {
            uint256 startEpoch = epochTimerStart[member];
            _burningEpoch = startEpoch + claimRewardsBurnEpochs;
            _burned = _burningEpoch <= treasury.epoch();
        } else {
            _burningEpoch = treasury.epoch() + claimRewardsBurnEpochs;
            _burned = false;
        }
    }

    /**
     * @notice Returns the current treasury epoch.
     * @return The current epoch.
     */
    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    /**
     * @notice Returns the timestamp for the next treasury epoch.
     * @return The next epoch's timestamp.
     */
    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    /**
     * @notice Returns the length (in seconds) of the next treasury epoch.
     * @return The epoch length.
     */
    function nextEpochLength() external view returns (uint256) {
        return treasury.nextEpochLength();
    }

    /**
     * @notice Retrieves the peg token price from the Treasury.
     * @param _token Peg token address.
     * @return The peg token price.
     */
    function getPegTokenPrice(address _token) external view returns (uint256) {
        return treasury.getPegTokenPrice(_token);
    }

    /**
     * @notice Retrieves the peg token price in Sonic by querying its oracle.
     * @param _token Peg token address.
     * @return The price in Sonic (scaled by 1e18).
     */
    function getPegTokenPriceInSonic(address _token) public view returns (uint256) {
        uint256 _decimals = IERC20Metadata(_token).decimals();
        try IOracle(tokenInSonicOracles[_token]).twap(_token, (10 ** _decimals)) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Boardroom: oracle failed");
        }
    }

    function loyaltyEpochsLength() external view returns (uint256) {
        return loyaltyEpochs.length;
    }

    /**
     * @notice Returns loyalty information for a member.
     * @param member The member's address.
     * @return _loyaltyDiscount The current loyalty discount in basis points.
     * @return _nextLoyaltyDiscount The next loyalty discount (if any).
     * @return _epochCount The number of epochs since 1st deposit (or 1st deposit after requestWithdrawal).
     * @return _epochToNext The number of epochs until the next discount level.
     */
    function loyaltyInfo(address member) public view returns (uint256 _loyaltyDiscount, uint256 _nextLoyaltyDiscount, uint256 _epochCount, uint256 _epochToNext) {
        _loyaltyDiscount = 0;
        _nextLoyaltyDiscount = loyaltyDiscounts[0];
        _epochCount = 0;
        _epochToNext = loyaltyEpochs[0];
        uint256 depositStart = epochDepositStart[member];
        if (depositStart > 0 && balanceOf(member) > 0) {
            uint256 currentEpoch = treasury.epoch();
            _epochCount = (currentEpoch + 1 >= depositStart) ? currentEpoch + 1 - depositStart : 0;
            uint256 len = loyaltyEpochs.length;
            uint256 i = len;
            for (; i > 0; i--) {
                if (_epochCount >= loyaltyEpochs[i - 1]) {
                    _loyaltyDiscount = loyaltyDiscounts[i - 1];
                    if (i < len) {
                        _nextLoyaltyDiscount = loyaltyDiscounts[i];
                        _epochToNext = loyaltyEpochs[i] - _epochCount;
                    } else {
                        _nextLoyaltyDiscount = 0;
                        _epochToNext = 0;
                    }
                    break;
                }
            }
            if (i == 0) {
                _epochToNext = loyaltyEpochs[0] - _epochCount;
            }
        }
    }

    /**
     * @notice Calculates the total Sonic fee for claiming rewards using Option 2.
     *         It also applies a loyalty discount based on the staking duration.
     * @param _user The address of the member.
     * @return totalSonicFee The total Sonic fee (in wei) required as a bribe.
     * @return discountedFee The discount amount applied.
     * @return loyaltyDiscount The loyalty discount in basis points.
     * @return nextLoyaltyDiscount The next loyalty discount in basis points.
     * @return epochCount The number of epochs since 1st deposit (or 1st deposit after requestWithdrawal).
     * @return epochToNext The remaining epochs until the next loyalty discount applies.
     */
    function getSonicFeeForOption2(address _user) external view returns (uint256 totalSonicFee, uint256 discountedFee, uint256 loyaltyDiscount, uint256 nextLoyaltyDiscount, uint256 epochCount, uint256 epochToNext) {
        uint256 len = pegTokens.length;
        totalSonicFee = 0;
        for (uint256 i = 0; i < len; ++i) {
            address token = pegTokens[i];
            uint256 reward = earned(token, _user);
            // Fee = (priceInSonic * reward * pegStabilityModuleFee) / 1e22.
            uint256 _decimals = IERC20Metadata(token).decimals();
            totalSonicFee += (getPegTokenPriceInSonic(token) * reward * pegStabilityModuleFee) / (10 ** (_decimals + 4));
        }
        (loyaltyDiscount, nextLoyaltyDiscount, epochCount, epochToNext) = loyaltyInfo(_user);
        if (totalSonicFee > 0 && loyaltyDiscount > 0) {
            discountedFee = (totalSonicFee * loyaltyDiscount) / 10000;
            totalSonicFee -= discountedFee;
        }
    }

    /**
     * @notice Returns the reward per share for a given peg token.
     * @param _token The peg token address.
     * @return The reward per share (scaled by 1e18).
     */
    function rewardPerShare(address _token) public view returns (uint256) {
        return getLatestSnapshot(_token).rewardPerShare;
    }

    /**
     * @notice Returns the number of peg tokens configured.
     * @return The count of peg tokens.
     */
    function numOfPegTokens() public view returns (uint256) {
        return pegTokens.length;
    }

    /**
     * @notice Calculates the reward earned by a member for a specific peg token.
     * @param _token The peg token address.
     * @param _member The member's address.
     * @return _earned The total earned reward.
     */
    function earned(address _token, address _member) public view returns (uint256 _earned) {
        _earned = _earnedOriginal(_token, _member);
        if (pegTokenElastics[_token]) {
            _earned = (_earned * pegTokenFirstGonsPerFragments[_token]) / pegTokenCurrentGonsPerFragments[_token];
        }
    }

    function _earnedOriginal(address _token, address _member) internal view returns (uint256 _earned) {
        uint256 latestRPS = getLatestSnapshot(_token).rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(_token, _member).rewardPerShare;
        _earned = ((balanceOf(_member) * (latestRPS - storedRPS)) / 1e18) + members[_token][_member].rewardEarned;
    }

    /**
     * @notice Returns the earned rewards for each peg token for a member.
     * @param _member The member's address.
     * @return _numOfPegTokens The number of peg tokens.
     * @return _pegTokenAddresses The list of peg token addresses.
     * @return _earnedPegTokens The list of earned rewards per peg token.
     */
    function earnedAll(address _member) external view returns (uint256 _numOfPegTokens, address[] memory _pegTokenAddresses, uint256[] memory _earnedPegTokens) {
        _numOfPegTokens = numOfPegTokens();
        _pegTokenAddresses = new address[](_numOfPegTokens);
        _earnedPegTokens = new uint256[](_numOfPegTokens);
        for (uint256 i = 0; i < _numOfPegTokens; i++) {
            _pegTokenAddresses[i] = pegTokens[i];
            _earnedPegTokens[i] = earned(_pegTokenAddresses[i], _member);
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Stakes share tokens into the boardroom.
     * Updates reward data, claims pending rewards if available, and resets the epoch timer.
     * @param amount The amount of shares to stake.
     */
    function stake(uint256 amount) public override onlyOneBlock nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot stake 0");
        uint256 currentEpoch = treasury.epoch();
        if (epochDepositStart[msg.sender] == 0 || balanceOf(msg.sender) == 0) {
            epochDepositStart[msg.sender] = currentEpoch + 1; // to calculate loyalty
        }
        if (epochTimerStart[msg.sender] + claimRewardsBurnEpochs <= treasury.epoch()) {
            _claimReward(0); // Option 2 may require sonic bribe cost calculation.
        } else {
            // Reset timer if reward lockup is still active.
            epochTimerStart[msg.sender] = currentEpoch;
        }
        super.stake(amount);
        epochTimerStart[msg.sender] = currentEpoch; // Reset lockup timer after staking.
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Initiates a withdrawal request by moving a specified amount of staked shares to a pending state.
     * The shares stop earning rewards immediately.
     * @param _amount The amount of shares to withdraw.
     */
    function requestWithdraw(uint256 _amount) public onlyOneBlock nonReentrant memberExists updateReward(msg.sender) {
        require(_amount > 0, "Boardroom: Cannot withdraw 0");
        uint256 currentEpoch = treasury.epoch();
        uint256 unlockEpoch = currentEpoch + withdrawLockupEpochs;
        epochDepositStart[msg.sender] = 0; // reset deposit time and remove any loyalty discount
        PendingWithdraw memory pending = pendingWithdrawals[msg.sender];
        pending.amount += _amount;
        pending.unlockEpoch = unlockEpoch;
        pendingWithdrawals[msg.sender] = pending;
        _sacrificeReward(_amount);
        super._withdraw(_amount);
        emit PendingWithdrawRequested(msg.sender, _amount, unlockEpoch);
    }

    /**
     * @notice Cancels the current pending withdrawal request, returning the pending shares back to staked balance.
     */
    function cancelPendingWithdraw() external onlyOneBlock nonReentrant updateReward(msg.sender) {
        PendingWithdraw memory pending = pendingWithdrawals[msg.sender];
        uint256 amountToCancel = pending.amount;
        require(amountToCancel > 0, "Boardroom: no pending withdraw to cancel");
        delete pendingWithdrawals[msg.sender]; // Clear pending withdrawal.
        super._cancelWithdraw(amountToCancel);
        epochDepositStart[msg.sender] = treasury.epoch() + 1;
        emit CancelPendingWithdraw(msg.sender, amountToCancel);
    }

    /**
     * @notice Finalizes a pending withdrawal after the lockup period has expired.
     * Transfers the pending share tokens back to the member's wallet.
     */
    function finalizeWithdraw() external onlyOneBlock nonReentrant updateReward(msg.sender) {
        PendingWithdraw memory pending = pendingWithdrawals[msg.sender];
        require(pending.unlockEpoch <= treasury.epoch(), "Boardroom: still in withdraw lockup");
        uint256 amountToWithdraw = pending.amount;
        delete pendingWithdrawals[msg.sender]; // Clear pending withdrawal.
        super._claimPendingWithdraw(amountToWithdraw);
        emit PendingWithdrawFinalized(msg.sender, amountToWithdraw);
    }

    /**
     * @notice Exits the boardroom by requesting withdrawal of all staked shares.
     */
    function exit() external {
        requestWithdraw(balanceOf(msg.sender));
    }

    /**
     * @dev Internal function that sacrifices a portion of a member's reward when initiating a withdrawal.
     * The sacrificed reward is burned.
     * @param _withdrawAmount The amount of staked shares being withdrawn.
     */
    function _sacrificeReward(uint256 _withdrawAmount) internal updateReward(msg.sender) {
        uint256 len = pegTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address token = pegTokens[i];
            uint256 reward = members[token][msg.sender].rewardEarned;
            if (reward > 0) {
                uint256 burnAmount = (reward * _withdrawAmount) / balanceOf(msg.sender);
                members[token][msg.sender].rewardEarned -= burnAmount;
                _safeTokenBurn(token, burnAmount);
                emit RewardSacrificed(token, msg.sender, burnAmount);
            }
        }
    }

    function claimReward() external {
        require(epochTimerStart[msg.sender] + rewardLockupEpochs <= treasury.epoch(), "Boardroom: still in reward lockup");
        _claimReward(1);
    }

    /**
     * @notice Claims accumulated rewards for all peg tokens for the caller.
     * Supports three options:
     * Option 1: Immediate Claim – burns a configurable percentage of the reward and pays out the rest.
     * Option 2: Option for direct claim with a Sonic bribe fee (for dynamic pricing via oracles).
     * @param _option The option selected (1 for Immediate, 2 for direct claim with Sonic bribe).
     */
    function claimRewardWithOption(uint256 _option) external payable {
        require(_option == 2 || msg.value == 0, "Only option 3 is payable");
        require(epochTimerStart[msg.sender] + rewardLockupEpochs <= treasury.epoch(), "Boardroom: still in reward lockup");
        _claimReward(_option);
    }

    /**
     * @dev Internal function to claim rewards based on the selected option.
     * For Option 1, a configurable percentage of the reward is burned.
     * For Option 2, a Sonic bribe fee is calculated and deducted.
     * @param _option The claim option selected.
     */
    function _claimReward(uint256 _option) internal updateReward(msg.sender) {
        bool willBurn = epochTimerStart[msg.sender] + claimRewardsBurnEpochs <= treasury.epoch();
        epochTimerStart[msg.sender] = treasury.epoch(); // Reset timer after claim.
        uint256 len = pegTokens.length;
        uint256 totalSonicFee = 0;
        for (uint256 i = 0; i < len; ++i) {
            address token = pegTokens[i];
            uint256 reward = earned(token, msg.sender);
            if (reward > 0) {
                if (willBurn) {
                    members[token][msg.sender].rewardEarned = 0;
                    _safeTokenBurn(token, reward);
                    emit RewardSacrificed(token, msg.sender, reward);
                } else {
                    if (_option == 1) {
                        // Option 1: Immediate Claim with configurable sacrifice.
                        members[token][msg.sender].rewardEarned = 0;
                        uint256 immediateReward = (reward * (10000 - immediateClaimSacrificePercent)) / 10000;
                        uint256 sacrifice = (reward * immediateClaimSacrificePercent) / 10000;
                        _safeTokenBurn(token, sacrifice);
                        _safeTokenTransfer(IERC20(token), msg.sender, immediateReward);
                        emit RewardPaid(token, msg.sender, immediateReward);
                        emit RewardSacrificed(token, msg.sender, sacrifice);
                    } else if (_option == 2) {
                        members[token][msg.sender].rewardEarned = 0;
                        // Option 2: Direct Claim with Sonic bribe fee.
                        uint256 _decimals = IERC20Metadata(token).decimals();
                        totalSonicFee += (getPegTokenPriceInSonic(token) * reward * pegStabilityModuleFee) / (10 ** (_decimals + 4));
                        _safeTokenTransfer(IERC20(token), msg.sender, reward);
                        emit RewardPaid(token, msg.sender, reward);
                    } else {
                        revert("Boardroom: unsupported claim option");
                    }
                }
            }
        }

        if (totalSonicFee > 0) {
            (uint256 loyaltyDiscount, , , ) = loyaltyInfo(msg.sender);
            uint256 discountedFee = 0;
            if (loyaltyDiscount > 0) {
                discountedFee = (totalSonicFee * loyaltyDiscount) / 10000;
                totalSonicFee -= discountedFee;
            }
            require(msg.value >= totalSonicFee, "Boardroom: insufficient Sonic for bribe fee");
            emit SonicBribed(msg.sender, totalSonicFee, discountedFee);
        }
        if (msg.value > totalSonicFee) {
            uint256 refund = msg.value - totalSonicFee;
            (bool success, ) = msg.sender.call{value: refund}("");
            require(success, "Boardroom: refund failed");
        }
    }

    /**
     * @notice Allocates seigniorage rewards for a specific peg token.
     * Callable by the Treasury contract.
     * @param _token The peg token address.
     * @param _amount The amount of reward to allocate.
     */
    function allocateSeignioragePegToken(address _token, uint256 _amount) external override onlyTreasury {
        require(_amount > 0, "Boardroom: Cannot allocate 0");
        uint256 totalStaked = totalSupply();
        require(totalStaked > 0, "Boardroom: Cannot allocate when totalSupply is 0");
        require(boardroomHistory[_token].length > 0, "Boardroom: No snapshot history for token");

        uint256 _normalisedAmount = _amount;

        // For elastic tokens, sync conversion factor if changed.
        if (pegTokenElastics[_token]) {
            uint256 _gonsPerFragment = IUFragments(_token).gonsPerFragment();
            if (pegTokenCurrentGonsPerFragments[_token] != _gonsPerFragment) {
                pegTokenCurrentGonsPerFragments[_token] = _gonsPerFragment;
                emit SyncElastic(_token, _gonsPerFragment);
            }
            if (pegTokenFirstGonsPerFragments[_token] != _gonsPerFragment) {
                _normalisedAmount = (_amount * _gonsPerFragment) / pegTokenFirstGonsPerFragments[_token];
            }
        }

        uint256 prevRPS = getLatestSnapshot(_token).rewardPerShare;
        uint256 nextRPS = prevRPS + (_normalisedAmount * 1e18) / totalStaked;

        BoardroomSnapshot memory newSnapshot = BoardroomSnapshot({time: block.number, rewardReceived: _amount, rewardPerShare: nextRPS});
        boardroomHistory[_token].push(newSnapshot);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardAdded(_token, msg.sender, _amount);
    }

    /**
     * @notice Syncs the reward token's conversion factor for elastic tokens.
     * Updates pegTokenCurrentGonsPerFragments for each elastic peg token and emits a SyncElastic event.
     */
    function sync() external {
        uint256 len = pegTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address token = pegTokens[i];
            if (pegTokenElastics[token]) {
                _syncGonsPerFragment(token);
            }
        }
    }

    function _syncGonsPerFragment(address _token) internal {
        uint256 _gonsPerFragment = IUFragments(_token).gonsPerFragment();
        require(_gonsPerFragment > 0, "Boardroom: invalid elastic supply token");
        if (pegTokenCurrentGonsPerFragments[_token] != _gonsPerFragment) {
            pegTokenCurrentGonsPerFragments[_token] = _gonsPerFragment;
            emit SyncElastic(_token, _gonsPerFragment);
        }
    }

    /**
     * @notice Safe token transfer function, in case rounding error causes insufficient balance.
     */
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

    /**
     * @notice Safe token burn function, in case rounding error causes insufficient balance.
     */
    function _safeTokenBurn(address _token, uint256 _amount) internal {
        uint256 _tokenBal = IERC20(_token).balanceOf(address(this));
        if (_tokenBal > 0) {
            if (_amount > _tokenBal) {
                IBasisAsset(_token).burn(_tokenBal);
            } else {
                IBasisAsset(_token).burn(_amount);
            }
        }
    }

    /* ========== GOVERNANCE & ADMIN FUNCTIONS ========== */

    /**
     * @notice Allows the owner to recover unsupported tokens (except core tokens).
     * @param _token The token to recover.
     * @param _amount The amount to recover.
     * @param _to The recipient address.
     */
    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOwner {
        require(_token != share, "Boardroom: share token");
        uint256 len = pegTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            require(address(_token) != pegTokens[i], "Boardroom: reward token");
        }
        _token.safeTransfer(_to, _amount);
    }

    /**
     * @notice Collects all native Sonic from the contract, wraps it into wS (Wrapped Sonic), and forwards it to pegStabilizationReserves.
     */
    function collectSonic() external {
        require(address(wrappedSonic) != address(0), "Boardroom: wrappedSonic not set");
        uint256 amount = address(this).balance;
        require(amount > 0, "Boardroom: No Sonic balance to collect");
        totalCollectedSonic += amount;
        wrappedSonic.deposit{value: amount}();
        IERC20(wrappedSonic).safeTransfer(pegStabilizationReserves, amount);
        emit SonicCollected(amount);
    }
}
