// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {SubAccountFactory} from "../src/core/subAccountFactory.sol";

contract MockTarget {
    uint256 public lastValue;
    bytes public lastData;

    function echoData(bytes calldata data) external pure returns (bytes memory) {
        return data;
    }

    function storeAndReturn(uint256 x) external payable returns (uint256) {
        lastValue = x;
        return x * 2;
    }

    function revertWithMessage() external pure {
        revert("MockTarget: intentional revert");
    }

    function revertEmpty() external pure {
        revert();
    }

    receive() external payable {}
}

contract SubAccountFactoryTest is Test {
    SubAccountFactory factory;
    MockTarget target;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    function setUp() public {
        factory = new SubAccountFactory();
        target = new MockTarget();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    // ============ DEPLOYMENT TESTS ============

    function test_deploysCorrectly_andPredictionMatches() public {
        address predicted = factory.getAccount(alice, 1);

        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        assertEq(subAccount, predicted, "predicted != actual");
        assertEq(subAccount.code.length, 91, "wrong code length");
    }

    function test_multipleDeployments_incrementNonce() public {
        address predicted1 = factory.getAccount(alice, 1);
        address predicted2 = factory.getAccount(alice, 2);
        address predicted3 = factory.getAccount(alice, 3);

        vm.startPrank(alice);
        address sub1 = factory.deploySubAccount();
        address sub2 = factory.deploySubAccount();
        address sub3 = factory.deploySubAccount();
        vm.stopPrank();

        assertEq(sub1, predicted1, "sub1 mismatch");
        assertEq(sub2, predicted2, "sub2 mismatch");
        assertEq(sub3, predicted3, "sub3 mismatch");
        assertTrue(sub1 != sub2 && sub2 != sub3, "duplicates");
    }

    function test_differentUsers_getDifferentAddresses() public {
        vm.prank(alice);
        address subAlice = factory.deploySubAccount();

        vm.prank(bob);
        address subBob = factory.deploySubAccount();

        assertTrue(subAlice != subBob, "same address for different users");
    }

    // ============ NON-MASTER BEHAVIOR ============

    function test_nonMaster_emptyCalldata_returnsEmpty() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        // Non-master sends ETH with empty calldata
        vm.prank(bob);
        (bool ok, bytes memory ret) = subAccount.call{value: 1 ether}("");
        
        assertTrue(ok, "should succeed");
        assertEq(ret.length, 0, "should return empty");
        assertEq(subAccount.balance, 1 ether, "ETH should be received");
    }

    function test_nonMaster_withCalldata_returnsEmpty_doesNotExecute() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 5 ether);

        // Non-master tries to withdraw ETH (should be ignored)
        uint256 bobBefore = bob.balance;
        bytes memory withdraw = _encodeSubAccountCall(bob, 1 ether, "");
        
        vm.prank(charlie); // charlie is not master
        (bool ok, bytes memory ret) = subAccount.call(withdraw);
        
        assertTrue(ok, "should not revert");
        assertEq(ret.length, 0, "should return empty");
        assertEq(bob.balance, bobBefore, "bob should NOT receive ETH");
        assertEq(subAccount.balance, 5 ether, "subaccount balance unchanged");
    }

    function test_nonMaster_cannotCallTarget() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        bytes memory payload = abi.encodeCall(MockTarget.storeAndReturn, (42));
        bytes memory callData = _encodeSubAccountCall(address(target), 0, payload);

        vm.prank(bob);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "should not revert");
        assertEq(ret.length, 0, "should return empty");
        assertEq(target.lastValue(), 0, "target should NOT be called");
    }

    // ============ MASTER BEHAVIOR ============

    function test_master_emptyCalldata_succeeds() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        // Master sends ETH with empty calldata (calldatasize < 64)
        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call{value: 2 ether}("");

        assertTrue(ok, "should succeed");
        assertEq(ret.length, 0, "should return empty");
        assertEq(subAccount.balance, 2 ether, "ETH should be received");
    }

    function test_master_withdrawETH() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 10 ether);

        uint256 bobBefore = bob.balance;
        bytes memory withdraw = _encodeSubAccountCall(bob, 3 ether, "");

        vm.prank(alice);
        (bool ok,) = subAccount.call(withdraw);

        assertTrue(ok, "withdraw failed");
        assertEq(bob.balance, bobBefore + 3 ether, "bob didn't receive ETH");
        assertEq(subAccount.balance, 7 ether, "wrong remaining balance");
    }

    function test_master_callContract_getsReturnData() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        bytes memory payload = abi.encodeCall(MockTarget.echoData, (hex"deadbeef1234"));
        bytes memory callData = _encodeSubAccountCall(address(target), 0, payload);

        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded, hex"deadbeef1234", "wrong return data");
    }

    function test_master_callContract_withValue() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 5 ether);

        uint256 targetBefore = address(target).balance;
        bytes memory payload = abi.encodeCall(MockTarget.storeAndReturn, (123));
        bytes memory callData = _encodeSubAccountCall(address(target), 2 ether, payload);

        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        uint256 result = abi.decode(ret, (uint256));
        assertEq(result, 246, "wrong return value");
        assertEq(target.lastValue(), 123, "target state not updated");
        assertEq(address(target).balance, targetBefore + 2 ether, "target didn't receive ETH");
        assertEq(subAccount.balance, 3 ether, "wrong subaccount balance");
    }

    function test_master_targetReverts_propagatesRevert() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        bytes memory payload = abi.encodeCall(MockTarget.revertWithMessage, ());
        bytes memory callData = _encodeSubAccountCall(address(target), 0, payload);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertFalse(ok, "should have reverted");
    }

    function test_master_targetRevertsEmpty_propagatesRevert() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        bytes memory payload = abi.encodeCall(MockTarget.revertEmpty, ());
        bytes memory callData = _encodeSubAccountCall(address(target), 0, payload);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertFalse(ok, "should have reverted");
    }

    // ============ EDGE CASES ============

    function test_master_calldata63bytes_goesToEmptyReturn() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 5 ether);

        // 63 bytes < 64, so should go to empty return path
        bytes memory shortData = new bytes(63);
        
        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call{value: 1 ether}(shortData);

        assertTrue(ok, "should succeed");
        assertEq(ret.length, 0, "should return empty");
        assertEq(subAccount.balance, 6 ether, "ETH should be received");
    }

    function test_master_calldata64bytes_executesCall() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 5 ether);

        // Exactly 64 bytes = [target(32)][value(32)] with empty data
        // This should execute a call to target with 0 data
        bytes memory callData = _encodeSubAccountCall(address(target), 1 ether, "");

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "call should succeed");
        assertEq(address(target).balance, 1 ether, "target should receive ETH");
    }

    function test_master_callNonExistentAddress_succeeds() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 5 ether);

        address nonExistent = address(0x1234567890123456789012345678901234567890);
        bytes memory callData = _encodeSubAccountCall(nonExistent, 1 ether, "");

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "call to non-existent should succeed");
        assertEq(nonExistent.balance, 1 ether, "should send ETH");
    }

    function test_master_callWithLargeData() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        bytes memory largeData = new bytes(1000);
        for (uint i = 0; i < 1000; i++) {
            largeData[i] = bytes1(uint8(i % 256));
        }
        
        bytes memory payload = abi.encodeCall(MockTarget.echoData, (largeData));
        bytes memory callData = _encodeSubAccountCall(address(target), 0, payload);

        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded, largeData, "large data mismatch");
    }

    // ============ HELPER ============

    function _encodeSubAccountCall(address _target, uint256 _value, bytes memory _data)
        internal
        pure
        returns (bytes memory)
    {
        // Layout: [target(32 right-aligned)][value(32)][data(rest)]
        return bytes.concat(abi.encode(_target, _value), _data);
    }
}
