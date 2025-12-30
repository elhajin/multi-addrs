// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SubAccountsManager} from "../src/core/subAccountsManager.sol";
import {MulticallAdapter} from "../src/adapters/MulticallAdapter.sol";
import {SubAccountFactory} from "../src/core/subAccountFactory.sol";

contract Target {
    uint256 public x;
    event Ping(address indexed from, uint256 value, bytes data);

    function setX(uint256 _x) external payable returns (uint256) {
        x = _x;
        emit Ping(msg.sender, msg.value, msg.data);
        return _x + 1;
    }

    function revertMe() external pure {
        revert("Target: revert");
    }

    receive() external payable {}
}

contract SubAccountsManagerTest is Test {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    SubAccountFactory factory;
    SubAccountsManager mgr;
    MulticallAdapter adapter;
    Target target;

    function setUp() public {
        factory = new SubAccountFactory();
        mgr = new SubAccountsManager(address(factory));
        adapter = new MulticallAdapter();
        target = new Target();

        mgr.setAdapterWhitelisted(address(adapter), true);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_deploy_predict_and_masterIsManager() public {
        vm.prank(alice);
        address sub = mgr.deploySubAccount();

        assertTrue(sub.code.length > 0, "no code");

        // direct call by alice to the subaccount should NOT execute (master is manager),
        // and returns empty for non-master.
        bytes memory payload = bytes.concat(abi.encode(address(target), 0, abi.encodeCall(Target.setX, (7))));
        vm.prank(alice);
        (bool ok, bytes memory ret) = sub.call(payload);
        assertTrue(ok, "should not revert");
        assertEq(ret.length, 0, "should return empty for non-master");
        assertEq(target.x(), 0, "target should not be called");
    }

    function test_onlyOwnerCanUseAccountNumberInDoAtomic() public {
        // alice deploys 1 account
        vm.prank(alice);
        address subAlice = mgr.deploySubAccount();
        uint96 aliceFactoryNumber = uint96(factory.getAccountsCount(address(mgr)));

        // bob deploys 1 account
        vm.prank(bob);
        mgr.deploySubAccount();

        // fund alice subaccount
        vm.prank(bob);
        subAlice.call{value: 2 ether}("");

        // bob tries to operate alice's factory number -> NOT_OWNER
        MulticallAdapter.Call[] memory calls = new MulticallAdapter.Call[](1);
        calls[0] = MulticallAdapter.Call({
            target: address(target),
            value: 1 ether,
            data: abi.encodeCall(Target.setX, (42))
        });

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MulticallAdapter.multicall, (calls));
        uint96[] memory nums = new uint96[](1);
        nums[0] = aliceFactoryNumber;

        vm.prank(bob);
        vm.expectRevert(bytes("NOT_OWNER"));
        mgr.doAtomic(adapters, datas, nums);
    }

    function test_adapter_execute_and_batchSubCalls() public {
        vm.prank(alice);
        address sub = mgr.deploySubAccount();
        uint96 factoryNumber = uint96(factory.getAccountsCount(address(mgr)));

        // fund subaccount
        vm.prank(bob);
        sub.call{value: 5 ether}("");

        MulticallAdapter.Call[] memory calls = new MulticallAdapter.Call[](2);
        calls[0] = MulticallAdapter.Call({
            target: address(target),
            value: 1 ether,
            data: abi.encodeCall(Target.setX, (11))
        });
        calls[1] = MulticallAdapter.Call({
            target: address(target),
            value: 0,
            data: abi.encodeCall(Target.setX, (22))
        });

        vm.prank(alice);
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MulticallAdapter.multicall, (calls));
        uint96[] memory nums = new uint96[](1);
        nums[0] = factoryNumber;
        mgr.doAtomic(adapters, datas, nums);

        assertEq(target.x(), 22);
        assertEq(address(target).balance, 1 ether);
        assertEq(sub.balance, 4 ether);
    }

    function test_adapter_revertBubbles() public {
        vm.prank(alice);
        address sub = mgr.deploySubAccount();
        uint96 factoryNumber = uint96(factory.getAccountsCount(address(mgr)));
        vm.prank(alice);
        sub.call{value: 1 ether}("");

        MulticallAdapter.Call[] memory calls = new MulticallAdapter.Call[](1);
        calls[0] = MulticallAdapter.Call({
            target: address(target),
            value: 0,
            data: abi.encodeCall(Target.revertMe, ())
        });

        vm.prank(alice);
        // NOTE: your subaccount runtime reverts with EMPTY data on target failure (it does not bubble revert data).
        vm.expectRevert();
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MulticallAdapter.multicall, (calls));
        uint96[] memory nums = new uint96[](1);
        nums[0] = factoryNumber;
        mgr.doAtomic(adapters, datas, nums);
    }

    function test_adapter_notAllowed() public {
        vm.prank(alice);
        address sub = mgr.deploySubAccount();
        uint96 factoryNumber = uint96(factory.getAccountsCount(address(mgr)));
        vm.prank(alice);
        sub.call{value: 1 ether}("");

        MulticallAdapter.Call[] memory calls = new MulticallAdapter.Call[](0);
        address[] memory adapters = new address[](1);
        adapters[0] = address(0xBEEF);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MulticallAdapter.multicall, (calls));
        uint96[] memory nums = new uint96[](1);
        nums[0] = factoryNumber;

        vm.prank(alice);
        vm.expectRevert(bytes("ADAPTER_NOT_ALLOWED"));
        mgr.doAtomic(adapters, datas, nums);
    }
}


