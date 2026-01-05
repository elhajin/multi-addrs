// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/// @title ISubAccountFactory
/// @author 
/// @notice Factory for deploying minimal sub-accounts that behave like EOAs under a single master
/// @dev Sub-accounts are 91-byte contracts with no storage. The master address is embedded in bytecode.
///      Each sub-account acts as an independent address that only its master can control.
///      
///      Sub-Account Behavior:
///      - Master calls with calldata >= 64 bytes: Executes `target.call{value}(data)` and returns result
///      - Master calls with calldata < 64 bytes: Accepts ETH, returns empty (deposit mode)
///      - Non-master calls: Always accepts ETH, returns empty, never executes
///      
///      Calldata Format (for master execution):
///      ```
///      [address target - 32 bytes][uint256 value - 32 bytes][bytes data - remaining]
///      ```
///      
///      Integration Patterns:
///      - EOA as master: User controls multiple addresses from one key
///      - Contract as master: Protocols can wrap sub-accounts to add features (batching, permissions, etc.)
///      - Router patterns: Batch operations across multiple sub-accounts via external routers
interface ISubAccountFactory {
    
    /// @notice Emitted when a new sub-account is deployed
    /// @param master The address that will control the sub-account (msg.sender at deploy time)
    /// @param subAccount The deterministic address of the deployed sub-account
    /// @param accountNumber The sequential account number for this master (1-indexed)
    event SubAccountDeployed(address indexed master, address indexed subAccount, uint96 accountNumber);

    /// @notice Deploy a new sub-account controlled by msg.sender
    /// @dev Uses CREATE2 with salt = (master << 96) | accountNumber for deterministic addresses.
    ///      Account numbers are sequential per master, starting from 1.
    /// @return subAccount The address of the newly deployed 91-byte sub-account
    function deploySubAccount() external returns (address subAccount);

    /// @notice Compute the deterministic address of a sub-account before or after deployment
    /// @dev Address is derived from CREATE2: keccak256(0xff ++ factory ++ salt ++ initCodeHash)
    /// @param user The master address
    /// @param accountNumber The account number (1-indexed, sequential per master)
    /// @return The sub-account address (exists whether deployed or not)
    function getAccount(address user, uint accountNumber) external view returns (address);

    /// @notice Get how many sub-accounts a master has deployed
    /// @param user The master address to query
    /// @return The total count of deployed sub-accounts (next deploy will be count + 1)
    function getAccountsCount(address user) external view returns (uint);

    /// @notice Check if a specific sub-account number has been deployed
    /// @dev Returns false for accountNumber = 0 (invalid) or accountNumber > deployed count
    /// @param user The master address
    /// @param accountNumber The account number to check (1-indexed)
    /// @return True if accountNumber is valid and has been deployed
    function isAccountDeployed(address user, uint accountNumber) external view returns (bool);
}
