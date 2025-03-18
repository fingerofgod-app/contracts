// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IUFragmentsPolicy.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title Orchestrator
 * @notice Coordinates rebase operations by executing a rebase policy and notifying downstream consumers.
 * @dev The contract stores a list of enabled transactions that are executed after each rebase.
 * Only the treasury or the owner can trigger the rebase process.
 */
contract Orchestrator is IUFragmentsPolicy, Ownable, ReentrancyGuard {
    struct Transaction {
        bool enabled;
        address destination;
        bytes data;
    }

    // List of transactions to be executed post-rebase.
    Transaction[] public transactions;

    /// @notice The underlying rebase policy contract.
    IUFragmentsPolicy public policy;

    /// @notice Address of the treasury contract.
    address public treasury;

    // ====== Events ======
    event PolicyUpdated(address indexed newPolicy);
    event TreasuryUpdated(address indexed newTreasury);
    event TransactionAdded(uint256 indexed index, address indexed destination);
    event TransactionRemoved(uint256 indexed index);
    event TransactionEnabled(uint256 indexed index, bool enabled);
    event RebaseExecuted(uint256 indexed epoch, uint256 transactionCount);

    // ====== Errors ======
    error UnauthorizedCall();
    error TransactionFailed();
    error InvalidIndex();

    /**
     * @notice Constructor
     * @param policy_ The address of the initial rebase policy contract.
     * @param treasury_ The address of the treasury contract.
     */
    constructor(address policy_, address treasury_) Ownable(msg.sender) {
        policy = IUFragmentsPolicy(policy_);
        emit PolicyUpdated(policy_);
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Modifier to restrict calls to only the treasury or the owner.
    modifier onlyTreasuryOrOwner() {
        if (msg.sender != owner() && msg.sender != treasury) {
            revert UnauthorizedCall();
        }
        _;
    }

    /// @notice Returns the current epoch from the policy.
    function epoch() external view override returns (uint256) {
        return policy.epoch();
    }

    /**
     * @notice Executes the rebase operation via the underlying policy and then
     * iterates through all enabled downstream transactions.
     * @dev If any transaction call fails, the entire rebase reverts.
     * @return _newSupply The new total supply after rebase.
     */
    function rebase() external override nonReentrant onlyTreasuryOrOwner returns (uint256 _newSupply) {
        uint256 preRebaseEpoch = policy.epoch();
        _newSupply = policy.rebase();
        uint256 executedTxCount = 0;

        // Execute all enabled downstream transactions.
        for (uint256 i = 0; i < transactions.length; i++) {
            Transaction storage t = transactions[i];
            if (t.enabled) {
                (bool success, ) = t.destination.call(t.data);
                if (!success) {
                    revert TransactionFailed();
                }
                executedTxCount++;
            }
        }

        emit RebaseExecuted(preRebaseEpoch + 1, executedTxCount);
    }

    /**
     * @notice Adds a new downstream transaction to be executed after each rebase.
     * @param destination The target contract address.
     * @param data The encoded function call data.
     */
    function addTransaction(address destination, bytes memory data) external onlyOwner {
        transactions.push(Transaction({enabled: true, destination: destination, data: data}));
        emit TransactionAdded(transactions.length - 1, destination);
    }

    /**
     * @notice Removes a transaction from the list.
     * @param index The index of the transaction to remove.
     */
    function removeTransaction(uint256 index) external onlyOwner {
        if (index >= transactions.length) revert InvalidIndex();

        // Replace the transaction to remove with the last one and pop from the array.
        if (index < transactions.length - 1) {
            transactions[index] = transactions[transactions.length - 1];
        }
        transactions.pop();
        emit TransactionRemoved(index);
    }

    /**
     * @notice Enables or disables a downstream transaction.
     * @param index The index of the transaction to modify.
     * @param enabled True to enable the transaction; false to disable.
     */
    function setTransactionEnabled(uint256 index, bool enabled) external onlyOwner {
        if (index >= transactions.length) revert InvalidIndex();
        transactions[index].enabled = enabled;
        emit TransactionEnabled(index, enabled);
    }

    /**
     * @notice Updates the rebase policy contract.
     * @param newPolicy The address of the new policy contract.
     */
    function setPolicy(address newPolicy) external onlyOwner {
        policy = IUFragmentsPolicy(newPolicy);
        emit PolicyUpdated(newPolicy);
    }

    /**
     * @notice Updates the treasury address.
     * @param newTreasury The new treasury address.
     */
    function setTreasury(address newTreasury) external onlyOwner {
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Returns the number of stored downstream transactions.
     * @return The number of transactions.
     */
    function transactionsSize() external view returns (uint256) {
        return transactions.length;
    }
}
