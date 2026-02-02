// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SubAccountFactory} from "../src/core/subAccountFactory.sol";
import {SubAccountRouter} from "../src/extensions/SubAccountRouter.sol";

contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external payable returns (uint256) {
        value = _value;
        return _value * 2;
    }

    receive() external payable {}
}

contract SubAccountRouterTest is Test {
    SubAccountFactory factory;
    SubAccountRouter router;
    MockTarget target;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event SubAccountCreated(address indexed user, address indexed subAccount, uint256 index);

    function setUp() public {
        factory = new SubAccountFactory();
        router = new SubAccountRouter(address(factory));
        target = new MockTarget();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_createSubAccount() public {
        vm.prank(alice);
        address sub = router.createSubAccount();

        assertEq(router.getSubAccountCount(alice), 1);
        assertEq(router.getSubAccounts(alice)[0], sub);
    }

    function test_execute_singleCall() public {
        vm.prank(alice);
        address sub = router.createSubAccount();
        vm.deal(sub, 10 ether);

        vm.prank(alice);
        bytes memory result = router.execute(0, address(target), 1 ether, abi.encodeCall(MockTarget.setValue, (42)));

        assertEq(target.value(), 42);
        assertEq(address(target).balance, 1 ether);
        assertEq(abi.decode(result, (uint256)), 84);
    }

    function test_batchExecute_multipleCalls() public {
        vm.startPrank(alice);
        router.createSubAccount();
        router.createSubAccount();
        vm.stopPrank();

        address[] memory subs = router.getSubAccounts(alice);
        vm.deal(subs[0], 5 ether);
        vm.deal(subs[1], 5 ether);

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        SubAccountRouter.Call[] memory calls = new SubAccountRouter.Call[](2);
        calls[0] = SubAccountRouter.Call({target: bob, value: 1 ether, data: ""});
        calls[1] = SubAccountRouter.Call({target: bob, value: 2 ether, data: ""});

        vm.prank(alice);
        router.batchExecute(indices, calls);

        assertEq(bob.balance, 103 ether); // 100 initial + 3 from sub-accounts
    }

    function test_otherUser_cannotExecute() public {
        vm.prank(alice);
        address sub = router.createSubAccount();
        vm.deal(sub, 10 ether);

        // Bob tries to execute on Alice's sub-account
        vm.prank(bob);
        vm.expectRevert(); // Array out of bounds - bob has no sub-accounts
        router.execute(0, bob, 5 ether, "");

        assertEq(sub.balance, 10 ether); // Unchanged
    }

    function test_multipleUsers_isolated() public {
        vm.prank(alice);
        address subAlice = router.createSubAccount();

        vm.prank(bob);
        address subBob = router.createSubAccount();

        assertTrue(subAlice != subBob);
        assertEq(router.getSubAccountCount(alice), 1);
        assertEq(router.getSubAccountCount(bob), 1);
    }
}
