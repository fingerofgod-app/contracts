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

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../owner/Operator.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title FOG
 * @dev A burnable, capped ERC20 token with a dynamic (time-based) cap.
 *      The cap increases linearly over a vesting period, and burned tokens permanently reduce minting space.
 */
contract FOG is ERC20Burnable, ERC20Capped, Operator {
    // Total supply parameters (using 18 decimals)
    uint256 public constant TOTAL_MAX_SUPPLY = 10000 ether; // 10K FOG
    uint256 public constant GENESIS_SUPPLY = 1 ether; // 1 RED minted at deployment

    // Allocation constants
    uint256 public constant LIQUIDITY_MINING_PROGRAM_ALLOCATION = 6000 ether; // 60%
    uint256 public constant PEG_STABILIZATION_RESERVES_ALLOCATION = 3000 ether; // 30%
    uint256 public constant DEV_FUND_ALLOCATION = 999 ether; // ~10% (accounting for genesis supply)

    // Vesting duration for additional minting (730 days = 2 years)
    uint256 public constant VESTING_DURATION = 730 days;

    address public treasury;

    // Vesting and reward distribution timing
    uint256 public startTime;
    uint256 public vestingEndTime;
    uint256 public lastClaimedTime;

    // Reward rates (tokens per second)
    uint256 public pegStabilizationReservesRewardRate;
    uint256 public devFundRewardRate;

    // Fund addresses
    address public pegStabilizationReserves;
    address public devFund;

    // Minting rate for new tokens (per second) over the vesting period
    uint256 public mintingRate;

    // Total tokens burned (which reduce minting space)
    uint256 public totalBurned;

    event TreasuryUpdated(address indexed newTreasury);

    /**
     * @dev Modifier to restrict functions to treasury or share printers.
     */
    modifier onlyPrinter() {
        require(treasury == msg.sender || ITreasury(treasury).isTokenPrinter(address(this), msg.sender), "!printer");
        _;
    }

    /**
     * @notice Constructor sets up the token, vesting schedule, and reward rates.
     * @param _startTime The timestamp when vesting starts.
     * @param _pegStabilizationReserves Address for Peg Stabilization Reserves rewards.
     * @param _devFund Address for Dev Fund rewards.
     */
    constructor(uint256 _startTime, address _pegStabilizationReserves, address _devFund) ERC20Capped(TOTAL_MAX_SUPPLY) ERC20("FOG", "FOG") {
        _mint(msg.sender, GENESIS_SUPPLY);

        startTime = _startTime; // 1742040000 - March 15, 2025, 12:00 PM UTC
        vestingEndTime = _startTime + VESTING_DURATION;
        lastClaimedTime = _startTime;

        pegStabilizationReservesRewardRate = PEG_STABILIZATION_RESERVES_ALLOCATION / VESTING_DURATION;
        devFundRewardRate = DEV_FUND_ALLOCATION / VESTING_DURATION;

        mintingRate = (TOTAL_MAX_SUPPLY - GENESIS_SUPPLY) / VESTING_DURATION;

        require(_pegStabilizationReserves != address(0), "Invalid pegStabilizationReserves address");
        pegStabilizationReserves = _pegStabilizationReserves;
        require(_devFund != address(0), "Invalid devFund address");
        devFund = _devFund;
    }

    function setTreasuryAddress(address _treasury) public onlyOwner {
        require(_treasury != address(0), "Treasury cannot be zero");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setPegStabilizationReserves(address _pegStabilizationReserves) external onlyOwner {
        require(_pegStabilizationReserves != address(0), "pegStabilizationReserves cannot be zero");
        pegStabilizationReserves = _pegStabilizationReserves;
    }

    function setDevFund(address _devFund) external onlyOwner {
        require(_devFund != address(0), "devFund cannot be zero");
        devFund = _devFund;
    }

    /* ========== VIEWS ================ */

    /**
     * @notice Returns the dynamic cap on the token's total supply.
     *         The cap increases linearly over the vesting period and is reduced by burned tokens.
     */
    function cap() public view override returns (uint256) {
        uint256 currentTime = block.timestamp;
        if (currentTime <= startTime) {
            return GENESIS_SUPPLY;
        }
        if (currentTime > vestingEndTime) {
            currentTime = vestingEndTime;
        }
        uint256 dynamicCap = GENESIS_SUPPLY + ((currentTime + 1 - startTime) * mintingRate);
        // Adjust for tokens burned
        if (dynamicCap <= totalBurned) {
            return 0;
        } else {
            dynamicCap -= totalBurned;
        }
        if (dynamicCap > TOTAL_MAX_SUPPLY) {
            dynamicCap = TOTAL_MAX_SUPPLY;
        }
        return dynamicCap;
    }

    /**
     * @notice Returns the pending rewards for DAO, Collateral, and Dev funds since the last claim.
     */
    function unclaimedFunds() public view returns (uint256 pendingReserves, uint256 pendingDev) {
        uint256 currentTime = block.timestamp;
        if (currentTime > vestingEndTime) {
            currentTime = vestingEndTime;
        }
        if (lastClaimedTime < currentTime) {
            uint256 elapsed = currentTime - lastClaimedTime;
            pendingReserves = elapsed * pegStabilizationReservesRewardRate;
            pendingDev = elapsed * devFundRewardRate;
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Claims pending rewards and mints tokens to the DAO, Collateral, and Dev funds.
     */
    function claimRewards() external {
        (uint256 _pendingReserves, uint256 _pendingDev) = unclaimedFunds();
        if (_pendingReserves > 0) {
            _mint(pegStabilizationReserves, _pendingReserves);
        }
        if (_pendingDev > 0) {
            _mint(devFund, _pendingDev);
        }
        lastClaimedTime = block.timestamp;
    }

    /**
     * @notice Mints new tokens to a recipient, respecting the dynamic cap.
     * @param recipient_ The address receiving the minted tokens.
     * @param amount_ The requested amount to mint.
     * @return True if tokens were minted.
     */
    function mint(address recipient_, uint256 amount_) public onlyPrinter returns (bool) {
        uint256 currentSupply = totalSupply();
        uint256 maxSupply = cap();
        if (currentSupply > maxSupply) return false;
        if (currentSupply + amount_ > maxSupply) {
            amount_ = maxSupply - currentSupply;
        }
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        return balanceOf(recipient_) > balanceBefore;
    }

    /**
     * @notice Burns tokens and updates totalBurned.
     * @param amount The amount to burn.
     */
    function burn(uint256 amount) public override {
        totalBurned += amount;
        super.burn(amount);
    }

    /**
     * @dev Override _update to use the ERC20Capped version.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        ERC20Capped._update(from, to, value);
    }

    /**
     * @notice Allows the owner to recover unsupported tokens.
     * @param token The ERC20 token to recover.
     * @param amount The amount to recover.
     * @param to The address to receive the tokens.
     */
    function governanceRecoverUnsupported(IERC20 token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Cannot transfer to zero address");
        token.transfer(to, amount);
    }
}
