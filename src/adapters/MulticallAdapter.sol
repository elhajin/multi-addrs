// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {SubAccountsManager} from "../core/subAccountsManager.sol";

/// @notice Stateless adapter executed via DELEGATECALL by `SubAccountsManager`.
/// @dev Calls must be from the manager, and `activeSubAccount()` must be set.
contract MulticallAdapter {
    error NotManagerContext();
    error CallFailed(uint256 index);

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Execute a batch of calls *from the currently active subaccount*.
    /// @dev The manager sets the active subaccount per action in `doAtomic/doNonAtomic`.
    function multicall(Call[] calldata calls) external returns (bytes[] memory rets) {
        // In delegatecall context, address(this) is the manager.
        SubAccountsManager mgr = SubAccountsManager(address(this));
        address sub = mgr.activeSubAccount();
        if (sub == address(0)) revert NotManagerContext();

        rets = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            bytes memory payload = bytes.concat(abi.encode(calls[i].target, calls[i].value), calls[i].data);
            (bool ok, bytes memory out) = sub.call(payload);
            if (!ok) {
                // bubble revert
                assembly {
                    revert(add(out, 0x20), mload(out))
                }
            }
            rets[i] = out;
        }
    }
}


