// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../lib/SafeMathInt.sol";
import "../lib/UInt256Lib.sol";
import "../utils/ContractGuard.sol";
import "../interfaces/IUFragmentsPolicy.sol";
import "../interfaces/IUFragments.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title UFragmentsPolicy
 * @notice Implements the monetary supply policy for uFragments (elastic supply stablecoin).
 *         This contract consults a treasury oracle to obtain the current token price and then
 *         computes a supply adjustment (rebase) if the price deviates from a target (1e18).
 *         The supply change is limited by configurable thresholds and delta rate caps.
 *         The computed rebase is applied by calling uFrags.rebase().
 *         Rebase information is stored per epoch.
 *
 * @dev This contract is upgradeable and uses OwnableUpgradeable for access control.
 */
contract UFragmentsPolicy is IUFragmentsPolicy, ReentrancyGuard, ContractGuard, OwnableUpgradeable {
    using SafeMathInt for int256;
    using UInt256Lib for uint256;

    /// @notice Stores rebase details for an epoch.
    struct EpochRebaseInfo {
        uint256 exchangeRate; // The observed token price at the time of rebase.
        uint256 targetRate; // The target price (typically 1e18).
        int256 requestedSupplyAdjustment; // The computed supply change (can be negative for contraction).
    }

    uint256 private constant ONE = 1e18;
    uint256 private constant MAX_SUPPLY = type(uint128).max; // Maximum allowed supply.

    /// @notice Mapping from epoch to its rebase information.
    mapping(uint256 => EpochRebaseInfo) public epochRebaseInfo;

    /// @notice Last epoch in which a rebase was executed.
    uint256 public lastRebaseEpoch;

    /// @notice Reference to the uFragments token contract.
    IUFragments public uFrags;

    // Rebase threshold and delta rate parameters.
    uint256 public expansionDeviationThreshold; // e.g. 1.04e18: if price > this, supply expands.
    uint256 public contractionDeviationThreshold; // e.g. 0.96e18: if price < this, supply contracts.
    uint256 public expansionDeltaRateMax; // Maximum allowed expansion delta (e.g. 0.5% = 5e15).
    uint256 public contractionDeltaRateMax; // Maximum allowed contraction delta (e.g. 1.0% = 1e16).

    /// @notice Address of the orchestrator authorized to trigger rebase.
    address public orchestrator;
    /// @notice Treasury contract providing price oracle data.
    ITreasury public treasury;

    // ====== Events ======
    event LogRebase(uint256 indexed epoch, uint256 exchangeRate, uint256 targetRate, int256 requestedSupplyAdjustment);

    // ====== Modifiers ======

    /// @notice Restricts calls to only the designated orchestrator.
    modifier onlyOrchestrator() {
        require(msg.sender == orchestrator, "UFragmentsPolicy: caller is not orchestrator");
        _;
    }

    /**
     * @notice Initializes the policy contract.
     * @param _uFrags The uFragments token contract address.
     * @param _treasury The Treasury contract address.
     */
    function initialize(IUFragments _uFrags, ITreasury _treasury) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        uFrags = _uFrags;
        treasury = _treasury;

        // Set default deviation thresholds.
        expansionDeviationThreshold = 104e16; // 1.04 * 1e18
        contractionDeviationThreshold = 96e16; // 0.96 * 1e18

        // Set maximum delta rates.
        expansionDeltaRateMax = 1e16; // 1.0%
        contractionDeltaRateMax = 2e16; // 2.0%
    }

    /// @notice Returns the current epoch from the treasury.
    function epoch() external view override returns (uint256) {
        return treasury.epoch();
    }

    /**
     * @notice Returns rebase information for a range of epochs.
     * @param _start The starting epoch.
     * @param _numEpochs The number of epochs to retrieve.
     * @return exchangeRates Array of observed exchange rates.
     * @return targetRates Array of target rates.
     * @return requestedSupplyAdjustments Array of computed supply adjustments.
     */
    function getEpochRebaseInfo(uint256 _start, uint256 _numEpochs) external view returns (uint256[] memory exchangeRates, uint256[] memory targetRates, int256[] memory requestedSupplyAdjustments) {
        exchangeRates = new uint256[](_numEpochs);
        targetRates = new uint256[](_numEpochs);
        requestedSupplyAdjustments = new int256[](_numEpochs);
        for (uint256 i = 0; i < _numEpochs; i++) {
            EpochRebaseInfo memory info = epochRebaseInfo[_start + i];
            exchangeRates[i] = info.exchangeRate;
            targetRates[i] = info.targetRate;
            requestedSupplyAdjustments[i] = info.requestedSupplyAdjustment;
        }
    }

    /**
     * @notice Returns the last epoch TWAP price from the treasury oracle.
     * @return The last epoch TWAP price.
     */
    function getConsultRate() public view returns (uint256) {
        return treasury.getPegTokenPrice(address(uFrags));
    }

    /**
     * @notice Returns the updated TWAP price from the treasury oracle.
     * @return The updated TWAP rate.
     */
    function getTwapRate() external view returns (uint256) {
        return treasury.getPegTokenUpdatedPrice(address(uFrags));
    }

    /**
     * @notice Executes a rebase operation if conditions are met.
     * @dev Only callable by the orchestrator and only once per epoch. It calculates the supply adjustment based on the current price,
     * applies the rebase on the uFragments token, stores the epoch's rebase info, and emits a LogRebase event.
     * @return supplyAfterRebase The new total supply after the rebase.
     */
    function rebase() external onlyOneBlock nonReentrant onlyOrchestrator returns (uint256 supplyAfterRebase) {
        uint256 epoch_ = treasury.epoch();
        require(epoch_ > lastRebaseEpoch, "UFragmentsPolicy: not opened");
        lastRebaseEpoch = epoch_;

        // Retrieve the current token price from the oracle.
        uint256 currentRate = getConsultRate();
        // Default target is ONE (i.e. 1e18).
        uint256 targetRate = ONE;
        uint256 absDelta = 0;
        int256 percentage = 0;

        // Determine if expansion is needed.
        if (currentRate > expansionDeviationThreshold) {
            targetRate = expansionDeviationThreshold;
            absDelta = currentRate - targetRate;
            if (absDelta > expansionDeltaRateMax) {
                absDelta = expansionDeltaRateMax;
            }
            percentage = absDelta.toInt256Safe();
        }
        // Determine if contraction is needed.
        else if (currentRate < contractionDeviationThreshold) {
            targetRate = contractionDeviationThreshold;
            absDelta = targetRate - currentRate;
            if (absDelta > contractionDeltaRateMax) {
                absDelta = contractionDeltaRateMax;
            }
            percentage = -(absDelta.toInt256Safe());
        }

        uint256 totalSupply = uFrags.totalSupply();
        int256 supplyDelta = percentage.mul(totalSupply.toInt256Safe()).div(ONE.toInt256Safe());
        supplyAfterRebase = uFrags.rebase(epoch_, supplyDelta);

        // Ensure the new supply does not exceed the maximum allowed.
        assert(supplyAfterRebase <= MAX_SUPPLY);

        // Record rebase info.
        epochRebaseInfo[epoch_] = EpochRebaseInfo({exchangeRate: currentRate, targetRate: targetRate, requestedSupplyAdjustment: supplyDelta});

        emit LogRebase(epoch_, currentRate, targetRate, supplyDelta);
    }

    /**
     * @notice Sets the orchestrator address.
     * @param _orchestrator The address authorized to trigger rebase operations.
     */
    function setOrchestrator(address _orchestrator) external onlyOwner {
        orchestrator = _orchestrator;
    }

    /**
     * @notice Updates the treasury address.
     * @param _treasury The new treasury contract address.
     */
    function setTreasury(ITreasury _treasury) external onlyOwner {
        treasury = _treasury;
    }

    /**
     * @notice Updates the expansion deviation threshold.
     * @param _threshold New expansion threshold (in 1e18 units).
     */
    function setExpansionDeviationThreshold(uint256 _threshold) external onlyOwner {
        expansionDeviationThreshold = _threshold;
    }

    /**
     * @notice Updates the contraction deviation threshold.
     * @param _threshold New contraction threshold (in 1e18 units).
     */
    function setContractionDeviationThreshold(uint256 _threshold) external onlyOwner {
        contractionDeviationThreshold = _threshold;
    }

    /**
     * @notice Updates the maximum expansion delta rate.
     * @param _rateMax New maximum expansion delta (in 1e18 units).
     */
    function setExpansionDeltaRateMax(uint256 _rateMax) external onlyOwner {
        expansionDeltaRateMax = _rateMax;
    }

    /**
     * @notice Updates the maximum contraction delta rate.
     * @param _rateMax New maximum contraction delta (in 1e18 units).
     */
    function setContractionDeltaRateMax(uint256 _rateMax) external onlyOwner {
        contractionDeltaRateMax = _rateMax;
    }
}
