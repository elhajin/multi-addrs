// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SubAccountFactory} from "../src/core/subAccountFactory.sol";

/// @dev Target that records all calls for verification
contract RecordingTarget {
    struct Call {
        address sender;
        uint256 value;
        bytes data;
    }

    Call[] public calls;
    bool public shouldRevert;
    bytes public revertData;
    bytes public returnData;

    function setRevert(bool _shouldRevert, bytes calldata _revertData) external {
        shouldRevert = _shouldRevert;
        revertData = _revertData;
    }

    function setReturnData(bytes calldata _returnData) external {
        returnData = _returnData;
    }

    function getCallCount() external view returns (uint256) {
        return calls.length;
    }

    function getLastCall() external view returns (address sender, uint256 value, bytes memory data) {
        require(calls.length > 0, "no calls");
        Call storage c = calls[calls.length - 1];
        return (c.sender, c.value, c.data);
    }

    fallback() external payable {
        calls.push(Call({sender: msg.sender, value: msg.value, data: msg.data}));

        if (shouldRevert) {
            if (revertData.length > 0) {
                assembly {
                    let ptr := mload(0x40)
                    let len := mload(add(sload(revertData.slot), 0x20))
                    mcopy(ptr, add(sload(revertData.slot), 0x20), len)
                    revert(ptr, len)
                }
            }
            revert();
        }

        bytes memory ret = returnData;
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }

    receive() external payable {
        calls.push(Call({sender: msg.sender, value: msg.value, data: ""}));

        if (shouldRevert) {
            revert();
        }
    }
}

contract SubAccountFuzzTest is Test {
    SubAccountFactory factory;
    RecordingTarget target;

    function setUp() public {
        factory = new SubAccountFactory();
        target = new RecordingTarget();
    }

    // ============ PROPERTY 1: Authorization ============
    // Non-master calls with calldata >= 64 bytes should NOT execute the inner call

    function testFuzz_nonMaster_cannotExecuteCall(
        address master,
        address attacker,
        address targetAddr,
        uint256 value,
        bytes calldata data
    ) public {
        vm.assume(master != address(0));
        vm.assume(attacker != master);
        vm.assume(targetAddr != address(0));

        // Deploy subaccount for master
        vm.prank(master);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 100 ether);

        uint256 targetBalanceBefore = targetAddr.balance;
        uint256 subAccountBalanceBefore = subAccount.balance;

        // Attacker tries to execute a call
        bytes memory callData = _encodeSubAccountCall(targetAddr, value, data);

        vm.prank(attacker);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        // Should succeed (return empty) but NOT execute
        assertTrue(ok, "should not revert");
        assertEq(ret.length, 0, "should return empty");
        assertEq(subAccount.balance, subAccountBalanceBefore, "balance should be unchanged");
        assertEq(targetAddr.balance, targetBalanceBefore, "target should not receive ETH");
    }

    // ============ PROPERTY 2: Non-master cannot drain ETH ============

    function testFuzz_nonMaster_cannotDrainETH(address master, address attacker, address recipient, uint256 amount)
        public
    {
        vm.assume(master != address(0));
        vm.assume(attacker != master);
        vm.assume(recipient != address(0));
        amount = bound(amount, 1, 50 ether);

        vm.prank(master);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 100 ether);

        uint256 subAccountBefore = subAccount.balance;
        uint256 recipientBefore = recipient.balance;

        bytes memory withdraw = _encodeSubAccountCall(recipient, amount, "");

        vm.prank(attacker);
        subAccount.call(withdraw);

        // Balance should be unchanged
        assertEq(subAccount.balance, subAccountBefore, "attacker drained ETH!");
        assertEq(recipient.balance, recipientBefore, "recipient got ETH from attacker!");
    }

    // ============ PROPERTY 3: Deterministic deployment ============

    function testFuzz_deterministicDeployment(address user, uint8 count) public {
        vm.assume(user != address(0));
        count = uint8(bound(count, 1, 10));

        // Get predictions first
        address[] memory predicted = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            predicted[i] = factory.getAccount(user, i + 1);
        }

        // Deploy and verify
        vm.startPrank(user);
        for (uint256 i = 0; i < count; i++) {
            address deployed = factory.deploySubAccount();
            assertEq(deployed, predicted[i], "prediction mismatch");
        }
        vm.stopPrank();
    }

    // ============ PROPERTY 4: Master can withdraw exact amount ============

    function testFuzz_master_withdrawExactAmount(
        address master,
        address recipient,
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(master != address(0));
        vm.assume(recipient != address(0));
        vm.assume(uint160(recipient) > 0x100); // avoid precompiles
        vm.assume(recipient.code.length == 0); // avoid contracts
        vm.assume(recipient != master);
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        withdrawAmount = bound(withdrawAmount, 0, depositAmount);

        vm.prank(master);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, depositAmount);

        uint256 recipientBefore = recipient.balance;

        bytes memory withdraw = _encodeSubAccountCall(recipient, withdrawAmount, "");

        vm.prank(master);
        (bool ok,) = subAccount.call(withdraw);

        assertTrue(ok, "withdraw failed");
        assertEq(recipient.balance, recipientBefore + withdrawAmount, "wrong amount received");
        assertEq(subAccount.balance, depositAmount - withdrawAmount, "wrong remaining");
    }

    // ============ PROPERTY 5: Return data forwarding ============

    function testFuzz_master_returnDataForwarded(address master, bytes calldata returnData) public {
        vm.assume(master != address(0));
        vm.assume(returnData.length < 10000); // reasonable size

        vm.prank(master);
        address subAccount = factory.deploySubAccount();

        target.setReturnData(returnData);

        bytes memory callData = _encodeSubAccountCall(address(target), 0, hex"12345678");

        vm.prank(master);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        assertEq(ret, returnData, "return data mismatch");
    }

    // ============ PROPERTY 6: Revert propagation ============

    function testFuzz_master_revertPropagated(address master, bytes calldata payload) public {
        vm.assume(master != address(0));
        vm.assume(payload.length < 1000);

        vm.prank(master);
        address subAccount = factory.deploySubAccount();

        target.setRevert(true, "");

        bytes memory callData = _encodeSubAccountCall(address(target), 0, payload);

        vm.prank(master);
        (bool ok,) = subAccount.call(callData);

        assertFalse(ok, "should have reverted");
    }

    // ============ PROPERTY 7: Anyone can deposit ETH ============

    function testFuzz_anyoneCanDeposit(address master, address depositor, uint256 amount) public {
        vm.assume(master != address(0));
        vm.assume(depositor != address(0));
        amount = bound(amount, 0, 100 ether);

        vm.prank(master);
        address subAccount = factory.deploySubAccount();

        vm.deal(depositor, amount);

        uint256 before = subAccount.balance;

        vm.prank(depositor);
        (bool ok,) = subAccount.call{value: amount}("");

        assertTrue(ok, "deposit failed");
        assertEq(subAccount.balance, before + amount, "wrong balance");
    }

    // ============ PROPERTY 8: Short calldata returns empty ============

    function testFuzz_shortCalldata_returnsEmpty(address master, uint8 length) public {
        vm.assume(master != address(0));
        length = uint8(bound(length, 0, 63));

        vm.prank(master);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 10 ether);

        bytes memory shortData = new bytes(length);

        // Even master with short calldata gets empty return
        vm.prank(master);
        (bool ok, bytes memory ret) = subAccount.call(shortData);

        assertTrue(ok, "should succeed");
        assertEq(ret.length, 0, "should return empty");
    }

    // ============ PROPERTY 9: Value transfer accuracy ============

    function testFuzz_valueTransferAccuracy(address master, uint256 value, bytes calldata payload) public {
        vm.assume(master != address(0));
        value = bound(value, 0, 50 ether);
        vm.assume(payload.length < 1000);

        vm.prank(master);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 100 ether);

        uint256 targetBefore = address(target).balance;
        uint256 subAccountBefore = subAccount.balance;

        bytes memory callData = _encodeSubAccountCall(address(target), value, payload);

        vm.prank(master);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        assertEq(address(target).balance, targetBefore + value, "target got wrong value");
        assertEq(subAccount.balance, subAccountBefore - value, "subaccount lost wrong amount");
    }

    // ============ PROPERTY 10: Different masters get isolated subaccounts ============

    function testFuzz_mastersIsolated(address master1, address master2, uint256 amount) public {
        vm.assume(master1 != address(0));
        vm.assume(master2 != address(0));
        vm.assume(master1 != master2);
        amount = bound(amount, 1, 50 ether);

        vm.prank(master1);
        address sub1 = factory.deploySubAccount();

        vm.prank(master2);
        address sub2 = factory.deploySubAccount();

        vm.deal(sub1, 100 ether);
        vm.deal(sub2, 100 ether);

        // master1 cannot drain sub2
        bytes memory withdraw = _encodeSubAccountCall(master1, amount, "");

        uint256 sub2Before = sub2.balance;

        vm.prank(master1);
        sub2.call(withdraw);

        assertEq(sub2.balance, sub2Before, "master1 drained master2's subaccount!");
    }

    // ============ HELPER ============

    function _encodeSubAccountCall(address _target, uint256 _value, bytes memory _data)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(abi.encode(_target, _value), _data);
    }
}

