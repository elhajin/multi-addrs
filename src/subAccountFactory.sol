// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;
/// @dev the code for the subAccount contract super minimal 
/// @dev it stores the master address at the end of the code like immutable styles 
/// @dev  called with calldata type : [address target , uint value , bytes data] , and it will call 
///       the target with the given value and data , and returns the  returned data or revert 
/// @dev INITCODE = [init prefix][runtime...][master(20 bytes appended at deploy time)]
/// @dev Fixed-size initcode prefix that returns exactly (RUNTIME_CODE || bytes20(master)).
///      runtimeLen = 75 bytes, so returnSize = 75 + 20 = 95 (0x5f) bytes.
///      initLen = 10 (0x0a) bytes.
///      Mnemonic:
///        PUSH0 PUSH1 0x0a PUSH1 0x5f CODECOPY PUSH0 PUSH1 0x5f RETURN
bytes constant INIT_CODE_PREFIX = hex"605b600a5f39605b5ff3"; 
bytes constant RUNTIME_CODE = hex"5f60143803601491395f5160601c33146016576043565b604036106043576040360360405f375f5f604036035f6020355f355af115603f573d5f5f3e3d5ff35b5f5ffd5b5f5ff3";
contract SubAccountFactory {
    
    mapping (address master => uint96 index) private _nonces;


    // function to deploy a new subAccount 
    
    function deploySubAccount() public returns (address) {
        _nonces[msg.sender]++;
        uint salt = uint(uint160(msg.sender) << 96) | _nonces[msg.sender];

        return _create_sub_account(salt, msg.sender);
    }

    function _create_sub_account(uint salt, address master) private returns (address subAccount) {
        // Append `master` to the end of initcode; initcode will return (runtime || master)
        bytes memory init = bytes.concat(INIT_CODE_PREFIX, RUNTIME_CODE, bytes20(master));

        assembly ("memory-safe") {
            subAccount := create2(0, add(init, 0x20), mload(init), salt)
        }
        require(subAccount != address(0), "CREATE2_FAILED");
    }

    /// @dev get the account of user using create 2 predection by number 
    /// @param user the user address
    /// @param accountNumber number of the account 
    function getAccount(address user, uint accountNumber) public view returns (address) {
        return _calculateAddress(user , (uint160(user) << 96) | accountNumber);
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