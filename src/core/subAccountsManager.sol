// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {SubAccountFactory} from "./subAccountFactory.sol";



/// @notice Manages per-user subaccounts (each user has many CREATE2 addresses),
///         but all subaccounts are mastered by THIS manager contract.
/// @dev Users can only operate their own derived subaccounts. Adapters allow extending features via delegatecall.
contract SubAccountsManager {
    event SubAccountDeployed(address indexed owner, uint96 indexed accountNumber, address indexed subAccount);
    event AdapterWhitelisted(address indexed adapter, bool allowed);
    event NonAtomicFailure(uint96 indexed accountNumber, address indexed adapter, bytes revertData);
    
    SubAccountFactory public immutable subAccountFactory;
    address public immutable admin;

    /// @dev whitelist of adapters allowed to be DELEGATECALL'ed
    mapping(address adapter => bool allowed) public adapterWhitelist;

    /// @dev factory account number to it's owner on the subAccountManager 
    mapping (uint96 accountNumber => address owner) private _accounts;
    /// @dev owner to the number of accounts deployed by him 
    mapping (address owner => uint96 accountsNumber) private _accountsNumber;
    /// @dev owner and account number to the pointer in the _accounts mapping 
    mapping ( bytes32 ownerAccNumber => uint96 pointer) private _accountsPointers;

    // -------------------------
    // Transient context (EIP-1153)
    // -------------------------
    // Adapters can read these via `activeOwner/activeAccountNumber/activeSubAccount`.
    uint256 private constant _T_OWNER = 0x6f776e65722e7375622e6d616e616765722e31; // "owner.sub.manager.1"
    uint256 private constant _T_ACCNO = 0x6163636e6f2e7375622e6d616e616765722e32; // "accno.sub.manager.2"
    uint256 private constant _T_SUB = 0x7375622e7375622e6d616e616765722e33; // "sub.sub.manager.3"

    constructor(address _subAccountFactory) {
        subAccountFactory = SubAccountFactory(_subAccountFactory);
        admin = msg.sender;
    }

    function setAdapterWhitelisted(address adapter, bool allowed) external {
        require(msg.sender == admin, "NOT_ADMIN");
        adapterWhitelist[adapter] = allowed;
        emit AdapterWhitelisted(adapter, allowed);
    }


    function deploySubAccount() public returns (address subAccount)  {
          subAccount = subAccountFactory.deploySubAccount();
          require(subAccount != address(0), "SUB_ACCOUNT_DEPLOYMENT_FAILED");
         uint96 accountNumber = uint96(subAccountFactory.getAccountsCount(address(this)));
         _accounts[accountNumber] = msg.sender;
         _accountsNumber[msg.sender]++;
         _accountsPointers[bytes32(uint(uint160(msg.sender) << 96) | _accountsNumber[msg.sender])] = accountNumber;
         emit SubAccountDeployed(msg.sender, accountNumber, subAccount);
    }



    function doAtomic(address[] memory adapter , bytes[] memory data, uint96[] memory accountNumber) public payable  {
        _do(adapter, data, accountNumber, true);
    } 

    function doNonAtomic(address[] memory adapters, bytes[] memory data, uint96[] memory accountNumber) public payable  {
        _do(adapters, data, accountNumber, false);
    }







    

    ////////////////////////////////// Getters //////////////////////////////////
    /// @dev Adapter context helpers (adapters can read these after DELEGATECALL).
    function activeOwner() external view returns (address) {
        address o;
        assembly ("memory-safe") {
            o := tload(_T_OWNER)
        }
        return o;
    }

    function activeAccountNumber() external view returns (uint96) {
        uint256 n;
        assembly ("memory-safe") {
            n := tload(_T_ACCNO)
        }
        return uint96(n);
    }

    function activeSubAccount() external view returns (address) {
        address a;
        assembly ("memory-safe") {
            a := tload(_T_SUB)
        }
        return a;
    }

    function getAccount(address owner, uint96 accountNumber) public view returns (address) {
        // accountNumber here is the OWNER's local index (1..N), not the factory-global account number.
        uint96 factoryAccountNumber = _accountsPointers[bytes32(uint(uint160(owner) << 96) | accountNumber)];
        require(factoryAccountNumber != 0, "ACCOUNT_NOT_FOUND");
        require(_accounts[factoryAccountNumber] == owner, "NOT_OWNER");
        return subAccountFactory.getAccount(address(this), factoryAccountNumber);
    }

    function hasAccount(address owner, uint96 accountNumber) public view returns (bool) {
        uint96 factoryAccountNumber = _accountsPointers[bytes32(uint(uint160(owner) << 96) | accountNumber)];
        return factoryAccountNumber != 0 && _accounts[factoryAccountNumber] == owner;
    }

    function getAccountsNumber(address owner) public view returns (uint96) {
        return _accountsNumber[owner];
    }

    function getAccountsPointers(address owner, uint96 accountNumber) public view returns (uint96) {
        return _accountsPointers[bytes32(uint(uint160(owner) << 96) | accountNumber)];
    }

    /// @notice Returns owner for a factory-global account number.
    function ownerOf(uint96 factoryAccountNumber) public view returns (address) {
        address owner = _accounts[factoryAccountNumber];
        require(owner != address(0), "ACCOUNT_NOT_FOUND");
        return owner;
    }

    /// @notice Returns subaccount address for a factory-global account number.
    function getAccountByFactoryNumber(uint96 factoryAccountNumber) public view returns (address) {
        address owner = _accounts[factoryAccountNumber];
        require(owner != address(0), "ACCOUNT_NOT_FOUND");
        return subAccountFactory.getAccount(address(this), factoryAccountNumber);
    }


    ////////////////////////////////// Internal Functions //////////////////////////////////

    function _checkEq(address a, address b) internal pure returns (bool) {
        return a == b;
    }

    function _do(
        address[] memory adapters,
        bytes[] memory datas,
        uint96[] memory factoryAccountNumbers,
        bool atomic
    ) internal {
        require(adapters.length == datas.length && datas.length == factoryAccountNumbers.length, "LENGTH_MISMATCH");
        // Prevent nested executions by checking transient owner slot.
        assembly ("memory-safe") {
            if tload(_T_OWNER) { revert(0, 0) }
        }

        for (uint256 i = 0; i < adapters.length; i++) {
            uint96 accountNum = factoryAccountNumbers[i];

            address owner = _accounts[accountNum];
            require(owner != address(0), "ACCOUNT_NOT_FOUND");
            require(owner == msg.sender, "NOT_OWNER");
            require(adapterWhitelist[adapters[i]], "ADAPTER_NOT_ALLOWED");

            address sub = subAccountFactory.getAccount(address(this), accountNum);
            require(sub.code.length > 0, "SUBACCOUNT_NOT_DEPLOYED");

            // set adapter context (transient)
            assembly ("memory-safe") {
                tstore(_T_OWNER, owner)
                tstore(_T_ACCNO, accountNum)
                tstore(_T_SUB, sub)
            }

            (bool ok, bytes memory ret) = adapters[i].delegatecall(datas[i]);

            // clear context (transient)
            assembly ("memory-safe") {
                tstore(_T_OWNER, 0)
                tstore(_T_ACCNO, 0)
                tstore(_T_SUB, 0)
            }

            if (!ok) {
                if (atomic) {
                    assembly {
                        revert(add(ret, 0x20), mload(ret))
                    }
                } else {
                    emit NonAtomicFailure(accountNum, adapters[i], ret);
                }
            }
        }
    }






    
}

