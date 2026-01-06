// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";
import {SubAccountFactory} from "../src/core/subAccountFactory.sol";

/// @title Deploy SubAccountFactory
/// @notice Deploys to the same address on all chains via CREATE3
/// @dev Dry run:  forge script script/Deploy.s.sol --rpc-url <rpc>
///      Deploy:   forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast --private-key <key>
contract Deploy is Script {
    bytes32 public constant SALT = keccak256("SubAccountFactory.v1");

    function run() public returns (address factory) {
        // Determine deployer
        address deployer;
        uint256 pk;
        bool isBroadcast;

        try vm.envUint("PRIVATE_KEY") returns (uint256 _pk) {
            pk = _pk;
            deployer = vm.addr(pk);
            isBroadcast = true;
        } catch {
            deployer = msg.sender;
            isBroadcast = false;
        }

        // Predict address
        address predicted = CREATE3.predictDeterministicAddress(SALT, deployer);

        console.log("Chain ID:    ", block.chainid);
        console.log("Deployer:    ", deployer);
        console.log("Predicted:   ", predicted);

        // Check if already deployed
        if (predicted.code.length > 0) {
            console.log("Status:       ALREADY DEPLOYED");
            _writeDeployment(predicted);
            return predicted;
        }

        if (!isBroadcast) {
            console.log("Status:       DRY RUN (add --broadcast --private-key to deploy)");
            return predicted;
        }

        // Deploy
        vm.startBroadcast(pk);
        factory = CREATE3.deployDeterministic(type(SubAccountFactory).creationCode, SALT);
        vm.stopBroadcast();

        require(factory == predicted, "Address mismatch");
        console.log("Status:       DEPLOYED");

        _writeDeployment(factory);
        return factory;
    }

    function _writeDeployment(address factory) internal {
        string memory json =
            string.concat('{"chainId":', vm.toString(block.chainid), ',"factory":"', vm.toString(factory), '"}');

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console.log("Written:     ", path);
    }
}
