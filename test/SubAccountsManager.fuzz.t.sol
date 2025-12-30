// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SubAccountsManager} from "../src/core/subAccountsManager.sol";
import {MulticallAdapter} from "../src/adapters/MulticallAdapter.sol";
import {SubAccountFactory} from "../src/core/subAccountFactory.sol";

contract FuzzTarget {
    uint256 public x;
    function setX(uint256 _x) external payable returns (uint256) {
        x = _x;
        return _x + 1;
    }
    receive() external payable {}
}

contract SubAccountsManagerFuzzTest is Test {
    SubAccountFactory factory;
    SubAccountsManager mgr;
    MulticallAdapter adapter;
    FuzzTarget target;

    function setUp() public {
        factory = new SubAccountFactory();
        mgr = new SubAccountsManager(address(factory));
        adapter = new MulticallAdapter();
        target = new FuzzTarget();
        mgr.setAdapterWhitelisted(address(adapter), true);
    }

    function testFuzz_predictMatchesDeploy(address user, uint8 n) public {
        vm.assume(user != address(0));
        n = uint8(bound(n, 1, 10));

        for (uint256 i = 1; i <= n; i++) {
            vm.prank(user);
            address deployed = mgr.deploySubAccount();
            assertTrue(deployed.code.length > 0, "no code");
        }
    }

    function testFuzz_nonOwnerCannotOperateOthers(address owner, address attacker, uint8 idx) public {
        vm.assume(owner != address(0));
        vm.assume(attacker != address(0));
        vm.assume(attacker != owner);
        idx = uint8(bound(idx, 1, 5));

        vm.prank(owner);
        mgr.deploySubAccount();
        uint96 ownerFactoryNumber = uint96(factory.getAccountsCount(address(mgr)));

        // Attacker trying to use owner's factory number should fail with NOT_OWNER.
        MulticallAdapter.Call[] memory calls = new MulticallAdapter.Call[](1);
        calls[0] = MulticallAdapter.Call({target: address(target), value: 0, data: abi.encodeCall(FuzzTarget.setX, (123))});
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MulticallAdapter.multicall, (calls));
        uint96[] memory nums = new uint96[](1);
        nums[0] = ownerFactoryNumber;

        vm.prank(attacker);
        vm.expectRevert(bytes("NOT_OWNER"));
        mgr.doAtomic(adapters, datas, nums);
    }

    function testFuzz_anyoneCanDeposit(address user, address depositor, uint96 amount) public {
        vm.assume(user != address(0));
        vm.assume(depositor != address(0));
        amount = uint96(bound(amount, 0, 10 ether));

        vm.prank(user);
        address sub = mgr.deploySubAccount();

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool ok,) = sub.call{value: amount}("");
        assertTrue(ok, "deposit failed");
        assertEq(sub.balance, amount, "wrong sub balance");
    }

    function testFuzz_adapterBatchCannotEscapeUserContext(address user, address attacker, uint96 amount) public {
        vm.assume(user != address(0));
        vm.assume(attacker != address(0));
        vm.assume(attacker != user);
        amount = uint96(bound(amount, 1, 10 ether));

        // user has one subaccount funded
        vm.prank(user);
        address subUser = mgr.deploySubAccount();
        vm.deal(subUser, 20 ether);

        // attacker has one subaccount funded
        vm.prank(attacker);
        address subAttacker = mgr.deploySubAccount();
        vm.deal(subAttacker, 20 ether);

        // When user executes adapter, it should only ever use user's derived subaccounts.
        MulticallAdapter.Call[] memory calls = new MulticallAdapter.Call[](1);
        calls[0] = MulticallAdapter.Call({target: attacker, value: amount, data: ""});

        uint256 attackerBefore = attacker.balance;

        vm.prank(user);
        uint96 userFactoryNumber = uint96(factory.getAccountsCount(address(mgr)) - 1); // user deployed first in this test
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MulticallAdapter.multicall, (calls));
        uint96[] memory nums = new uint96[](1);
        nums[0] = userFactoryNumber;
        mgr.doAtomic(adapters, datas, nums);

        assertEq(attacker.balance, attackerBefore + amount, "attacker didn't receive ETH");
        assertEq(subUser.balance, 20 ether - amount, "user sub wrong");
        assertEq(subAttacker.balance, 20 ether, "attacker sub should be untouched");
    }
}


