// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ISubAccountFactory} from "../interfaces/ISubAccountFactory.sol";

/// @title SubAccountRouter
/// @notice Deploy and manage multiple sub-accounts where this contract is the master
/// @dev Users interact through this router; the router controls all sub-accounts it deploys
contract SubAccountRouter {
    ISubAccountFactory public immutable factory;

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    mapping(address user => address[] subAccounts) private _userAccounts;

    event SubAccountCreated(address indexed user, address indexed subAccount, uint256 index);

    constructor(address _factory) {
        factory = ISubAccountFactory(_factory);
    }

    /// @notice Deploy a new sub-account owned by this router, tracked for user
    function createSubAccount() external returns (address subAccount) {
        subAccount = factory.deploySubAccount();
        _userAccounts[msg.sender].push(subAccount);
        emit SubAccountCreated(msg.sender, subAccount, _userAccounts[msg.sender].length - 1);
    }

    /// @notice Execute a call from user's sub-account
    /// @param accountIndex Index of user's sub-account (0-indexed)
    /// @param target Target contract to call
    /// @param value ETH value to send
    /// @param data Calldata for the target
    function execute(uint256 accountIndex, address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory)
    {
        address subAccount = _userAccounts[msg.sender][accountIndex];
        bytes memory payload = abi.encodePacked(abi.encode(target, value), data);
        (bool ok, bytes memory ret) = subAccount.call(payload);
        require(ok, "SubAccountRouter: call failed");
        return ret;
    }

    /// @notice Execute multiple calls from user's sub-accounts
    /// @param accountIndices Array of sub-account indices
    /// @param calls Array of calls (must match length of accountIndices)
    function batchExecute(uint256[] calldata accountIndices, Call[] calldata calls)
        external
        returns (bytes[] memory results)
    {
        require(accountIndices.length == calls.length, "length mismatch");
        results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            address subAccount = _userAccounts[msg.sender][accountIndices[i]];
            bytes memory payload = abi.encodePacked(
                abi.encode(calls[i].target, calls[i].value),
                calls[i].data
            );
            (bool ok, bytes memory ret) = subAccount.call(payload);
            require(ok, "SubAccountRouter: call failed");
            results[i] = ret;
        }
    }

    /// @notice Get all sub-accounts for a user
    function getSubAccounts(address user) external view returns (address[] memory) {
        return _userAccounts[user];
    }

    /// @notice Get sub-account count for a user
    function getSubAccountCount(address user) external view returns (uint256) {
        return _userAccounts[user].length;
    }
}
