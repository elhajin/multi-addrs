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

contract BigReturner {
    function returnBig(uint256 size) external pure returns (bytes memory) {
        return new bytes(size);
    }
}

contract RevertWithCustom {
    error CustomError(string message);

    function fail() external pure {
        revert CustomError("intentional failure");
    }
}

contract ETHSender {
    function sendTo(address recipient, uint256 amount) external {
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "send failed");
    }

    receive() external payable {}
}

contract ContractMaster {
    SubAccountFactory public factory;

    constructor(address _factory) {
        factory = SubAccountFactory(_factory);
    }

    function deploy() external returns (address) {
        return factory.deploySubAccount();
    }

    function withdraw(address subAccount, address recipient, uint256 amount) external {
        bytes memory callData = abi.encode(recipient, amount);
        (bool ok,) = subAccount.call(callData);
        require(ok, "withdraw failed");
    }
}

contract SubAccountFactoryTest is Test {
    SubAccountFactory factory;
    MockTarget target;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    event SubAccountDeployed(address indexed master, address indexed subAccount, uint96 accountNumber);

    function setUp() public {
        factory = new SubAccountFactory();
        target = new MockTarget();
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(charlie, 1000 ether);
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

    // ============ EVENT TESTS ============

    function test_deployment_emitsEvent() public {
        address predicted = factory.getAccount(alice, 1);

        vm.expectEmit(true, true, false, true);
        emit SubAccountDeployed(alice, predicted, 1);

        vm.prank(alice);
        factory.deploySubAccount();
    }

    function test_multipleDeployments_emitCorrectAccountNumbers() public {
        vm.startPrank(alice);

        vm.expectEmit(true, false, false, true);
        emit SubAccountDeployed(alice, factory.getAccount(alice, 1), 1);
        factory.deploySubAccount();

        vm.expectEmit(true, false, false, true);
        emit SubAccountDeployed(alice, factory.getAccount(alice, 2), 2);
        factory.deploySubAccount();

        vm.expectEmit(true, false, false, true);
        emit SubAccountDeployed(alice, factory.getAccount(alice, 3), 3);
        factory.deploySubAccount();

        vm.stopPrank();
    }

    // ============ isAccountDeployed TESTS ============

    function test_isAccountDeployed_returnsFalseForZero() public {
        vm.prank(alice);
        factory.deploySubAccount();

        assertFalse(factory.isAccountDeployed(alice, 0), "account 0 should not exist");
    }

    function test_isAccountDeployed_correctAfterFirstDeploy() public {
        assertFalse(factory.isAccountDeployed(alice, 1), "should be false before deploy");

        vm.prank(alice);
        factory.deploySubAccount();

        assertTrue(factory.isAccountDeployed(alice, 1), "should be true after deploy");
        assertFalse(factory.isAccountDeployed(alice, 2), "next should still be false");
    }

    function test_isAccountDeployed_correctForMultipleAccounts() public {
        vm.startPrank(alice);
        factory.deploySubAccount();
        factory.deploySubAccount();
        factory.deploySubAccount();
        vm.stopPrank();

        assertFalse(factory.isAccountDeployed(alice, 0), "0 never deployed");
        assertTrue(factory.isAccountDeployed(alice, 1), "1 deployed");
        assertTrue(factory.isAccountDeployed(alice, 2), "2 deployed");
        assertTrue(factory.isAccountDeployed(alice, 3), "3 deployed");
        assertFalse(factory.isAccountDeployed(alice, 4), "4 not deployed");
        assertFalse(factory.isAccountDeployed(alice, 100), "100 not deployed");
    }

    // ============ NON-MASTER BEHAVIOR ============

    function test_nonMaster_emptyCalldata_returnsEmpty() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

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

        uint256 bobBefore = bob.balance;
        bytes memory withdraw = _encodeSubAccountCall(bob, 1 ether, "");

        vm.prank(charlie);
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

    // ============ CALLDATA SIZE EDGE CASES ============

    function test_master_calldata63bytes_goesToEmptyReturn() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 5 ether);

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

        bytes memory callData = _encodeSubAccountCall(address(target), 1 ether, "");

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "call should succeed");
        assertEq(address(target).balance, 1 ether, "target should receive ETH");
    }

    // ============ GAS TESTS ============

    function test_gas_deployment() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        factory.deploySubAccount();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas for deployment:", gasUsed);
        assertLt(gasUsed, 100000, "deployment should be cheap");
    }

    function test_gas_simpleETHTransfer() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 10 ether);

        bytes memory callData = abi.encode(bob, 1 ether);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        (bool ok,) = subAccount.call(callData);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok);
        console.log("Gas for ETH transfer:", gasUsed);
        assertLt(gasUsed, 30000, "ETH transfer should be very cheap");
    }

    function test_gas_contractCall() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        BigReturner bigTarget = new BigReturner();
        bytes memory payload = abi.encodeCall(BigReturner.returnBig, (100));
        bytes memory callData = bytes.concat(abi.encode(address(bigTarget), 0), payload);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        (bool ok,) = subAccount.call(callData);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok);
        console.log("Gas for contract call:", gasUsed);
    }

    // ============ MORE EDGE CASES ============

    function test_largeReturnData() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        BigReturner bigTarget = new BigReturner();
        bytes memory payload = abi.encodeCall(BigReturner.returnBig, (10000));
        bytes memory callData = bytes.concat(abi.encode(address(bigTarget), 0), payload);

        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded.length, 10000, "wrong return size");
    }

    function test_master_canCallSelf() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 10 ether);

        bytes memory callData = abi.encode(subAccount, 0);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "self-call should succeed");
        assertEq(subAccount.balance, 10 ether, "balance unchanged");
    }

    function test_master_canCallFactory() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        bytes memory payload = abi.encodeCall(SubAccountFactory.getAccountsCount, (alice));
        bytes memory callData = bytes.concat(abi.encode(address(factory), 0), payload);

        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertTrue(ok, "factory call failed");
        uint256 count = abi.decode(ret, (uint256));
        assertEq(count, 1, "should return 1 account");
    }

    function test_master_zeroValueTransfer() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        uint256 bobBefore = bob.balance;
        bytes memory callData = abi.encode(bob, 0);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "zero transfer failed");
        assertEq(bob.balance, bobBefore, "bob balance unchanged");
    }

    function test_master_transferAllBalance() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 50 ether);

        uint256 bobBefore = bob.balance;
        bytes memory callData = abi.encode(bob, 50 ether);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "full transfer failed");
        assertEq(subAccount.balance, 0, "subaccount should be empty");
        assertEq(bob.balance, bobBefore + 50 ether, "bob should receive all");
    }

    function test_master_transferMoreThanBalance_reverts() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();
        vm.deal(subAccount, 1 ether);

        bytes memory callData = abi.encode(bob, 100 ether);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertFalse(ok, "should fail - insufficient balance");
    }

    function test_master_targetRevertsWithData_noDataForwarded() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        RevertWithCustom revertTarget = new RevertWithCustom();
        bytes memory payload = abi.encodeCall(RevertWithCustom.fail, ());
        bytes memory callData = bytes.concat(abi.encode(address(revertTarget), 0), payload);

        vm.prank(alice);
        (bool ok, bytes memory ret) = subAccount.call(callData);

        assertFalse(ok, "should revert");
        // Minimal runtime reverts with empty data for gas efficiency
        assertEq(ret.length, 0, "minimal runtime reverts with empty data");
    }

    function test_subAccount_receivesETH_whileExecuting() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        ETHSender sender = new ETHSender();
        vm.deal(address(sender), 10 ether);

        bytes memory payload = abi.encodeCall(ETHSender.sendTo, (subAccount, 5 ether));
        bytes memory callData = bytes.concat(abi.encode(address(sender), 0), payload);

        vm.prank(alice);
        (bool ok,) = subAccount.call(callData);

        assertTrue(ok, "call failed");
        assertEq(subAccount.balance, 5 ether, "should receive ETH during call");
    }

    function test_multipleSubAccounts_sameBlock() public {
        uint256 bobBefore = bob.balance;

        vm.startPrank(alice);
        address sub1 = factory.deploySubAccount();
        address sub2 = factory.deploySubAccount();
        address sub3 = factory.deploySubAccount();
        vm.stopPrank();

        assertTrue(sub1 != sub2 && sub2 != sub3 && sub1 != sub3, "all different");

        vm.deal(sub1, 1 ether);
        vm.deal(sub2, 1 ether);
        vm.deal(sub3, 1 ether);

        vm.startPrank(alice);
        (bool ok1,) = sub1.call(abi.encode(bob, 0.3 ether));
        (bool ok2,) = sub2.call(abi.encode(bob, 0.4 ether));
        (bool ok3,) = sub3.call(abi.encode(bob, 0.3 ether));
        vm.stopPrank();

        assertTrue(ok1 && ok2 && ok3, "all should succeed");
        assertEq(bob.balance, bobBefore + 1 ether, "bob received from all");
    }

    function test_getAccount_largeAccountNumber() public view {
        address predicted = factory.getAccount(alice, type(uint96).max);
        assertTrue(predicted != address(0), "should return valid address");
    }

    function test_masterIsContract() public {
        ContractMaster master = new ContractMaster(address(factory));

        address subAccount = master.deploy();
        vm.deal(subAccount, 10 ether);

        uint256 bobBefore = bob.balance;
        master.withdraw(subAccount, bob, 5 ether);

        assertEq(bob.balance, bobBefore + 5 ether, "contract master should work");
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
        for (uint256 i = 0; i < 1000; i++) {
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
        return bytes.concat(abi.encode(_target, _value), _data);
    }
}
