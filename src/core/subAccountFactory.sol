// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ISubAccountFactory} from "../interfaces/ISubAccountFactory.sol";

/// @dev Sub-account runtime bytecode (71 bytes). Master address appended at deploy → 91 bytes total.
///      
///      Pseudocode:
///      ```
///      master = code[codesize - 20 : codesize]  // last 20 bytes of deployed code
///      if (caller == master && calldatasize >= 64):
///          target = calldata[0:32]
///          value  = calldata[32:64]
///          data   = calldata[64:]
///          success, ret = target.call{value}(data)
///          if success: return ret
///          else: revert("")
///      else:
///          return ""  // accept ETH, do nothing
///      ```
bytes constant RUNTIME_CODE = hex"5f60143803601491395f5160601c33146016576043565b604036106043576040360360405f375f5f604036035f6020355f355af115603f573d5f5f3e3d5ff35b5f5ffd5b5f5ff3";

/// @dev Initcode prefix (10 bytes). Deploys RUNTIME_CODE + master (20 bytes appended at creation).
///      PUSH1 0x5b PUSH1 0x0a PUSH0 CODECOPY PUSH1 0x5b PUSH0 RETURN
bytes constant INIT_CODE_PREFIX = hex"605b600a5f39605b5ff3"; 

/// @title SubAccountFactory
/// @notice See {ISubAccountFactory}
contract SubAccountFactory is ISubAccountFactory {
    
    mapping (address master => uint96 index) private _nonces;

    /// @inheritdoc ISubAccountFactory
    function deploySubAccount() public returns (address subAccount) {
        uint96 accountNumber = ++_nonces[msg.sender];
        uint salt = uint(uint160(msg.sender) << 96) | accountNumber;
        subAccount = _createSubAccount(salt, msg.sender);
        emit SubAccountDeployed(msg.sender, subAccount, accountNumber);
    }

    /// @inheritdoc ISubAccountFactory
    function getAccount(address user, uint accountNumber) public view returns (address) {
        return _calculateAddress(user, (uint160(user) << 96) | accountNumber);
    }

    /// @inheritdoc ISubAccountFactory
    function getAccountsCount(address user) public view returns (uint) {
        return _nonces[user];
    }

    /// @inheritdoc ISubAccountFactory
    function isAccountDeployed(address user, uint accountNumber) public view returns (bool) {
        return accountNumber != 0 && _nonces[user] >= accountNumber;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────────

    function _createSubAccount(uint salt, address master) private returns (address subAccount) {
        bytes memory init = bytes.concat(INIT_CODE_PREFIX, RUNTIME_CODE, bytes20(master));
        assembly ("memory-safe") {
            subAccount := create2(0, add(init, 0x20), mload(init), salt)
        }
        require(subAccount != address(0), "CREATE2_FAILED");
    }

    function _calculateAddress(address user, uint salt) private view returns (address) {
        bytes memory init = bytes.concat(INIT_CODE_PREFIX, RUNTIME_CODE, bytes20(user));
        return address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(init)
        )))));
    }
}
