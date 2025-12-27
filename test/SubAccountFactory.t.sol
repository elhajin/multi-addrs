// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {SubAccountFactory} from "../src/subAccountFactory.sol";

contract MockTarget {
    function echoData(bytes calldata data) external pure returns (bytes memory) {
        return data;
    }

    function revertWithMessage() external pure {
        revert("MockTarget: intentional revert");
    }

    receive() external payable {}
}

contract SubAccountFactoryTest is Test {
    SubAccountFactory factory;
    MockTarget target;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new SubAccountFactory();
        target = new MockTarget();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_deploysCorrectly_andPredictionMatches() public {
        address predicted = factory.getAccount(alice, 1);

        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        assertEq(subAccount, predicted, "predicted != actual");
        assertTrue(subAccount.code.length == 91, "no code");
        console.log("subAccount len ", subAccount.code.length);
    }


    function test_calls_ethFlows_andReverts_areCorrect() public {
        vm.prank(alice);
        address subAccount = factory.deploySubAccount();

        // 1) Direct ETH deposit by non-master with empty calldata should succeed.
        vm.prank(bob);
        (bool okNonMasterDeposit,) = subAccount.call{value: 1 ether}("");
        assertTrue(okNonMasterDeposit, "non-master direct deposit failed");
        assertEq(subAccount.balance, 1 ether, "subaccount balance after non-master deposit");


        vm.prank(alice);
        (bool okMasterEmptyDeposit,) = subAccount.call{value: 2 ether}("");
        assertEq(subAccount.balance, 3 ether, "balance should be unchanged on failed call");

        // 3) Master withdraws ETH from subaccount to bob (target=bob, empty data).
        uint256 bobBefore = bob.balance;
        bytes memory withdraw = _encodeSubAccountCall(bob, 3 ether, "");
        vm.prank(alice);
        (bool okWithdraw,) = subAccount.call(withdraw);
        assertTrue(okWithdraw, "withdraw failed");
        assertEq(bob.balance, bobBefore + 3 ether, "bob didn't receive ETH");
        assertEq(subAccount.balance, 0 ether, "subaccount balance after withdraw");
        console.log("bob balance        ", bob.balance);
        console.log("subAccount balance ", subAccount.balance);

        // 4) Master calls target and checks returned data.
        // bytes memory payload = abi.encodeCall(MockTarget.echoData, (hex"deadbeef"));
        // bytes memory callEcho = _encodeSubAccountCall(address(target), 0, payload);
        // vm.prank(alice);
        // (bool okEcho, bytes memory retEcho) = subAccount.call(callEcho);
        // assertTrue(okEcho, "echo call failed");
        // bytes memory decoded = abi.decode(retEcho, (bytes));
        // assertEq(decoded, hex"deadbeef", "bad returned data");

        // // 5) If target reverts, the subaccount should revert (runtime reverts with empty data).
        // bytes memory callRevert = _encodeSubAccountCall(address(target), 0, abi.encodeCall(MockTarget.revertWithMessage, ()));
        // vm.prank(alice);
        // (bool okRevert,) = subAccount.call(callRevert);
        // assertFalse(okRevert, "expected revert");

        // // 6) Non-master call should return empty and not execute the call.
        // bytes memory nonMasterCall = _encodeSubAccountCall(address(target), 0, payload);
        // vm.prank(bob);
        // (bool okNonMaster, bytes memory retNonMaster) = subAccount.call(nonMasterCall);
        // assertTrue(okNonMaster, "non-master should not revert");
        // assertEq(retNonMaster.length, 0, "non-master should return empty");
    }

    function _encodeSubAccountCall(address _target, uint256 _value, bytes memory _data)
        internal
        pure
        returns (bytes memory)
    {
        // Layout expected by runtime:
        // [target(32 LEFT-ALIGNED)][value(32)][data(rest)]
        bytes memory data = bytes.concat(abi.encode(_target, _value), _data);
        console.logBytes( data) ;
        return data;
    }
}

