// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoDeployment} from "./DeployPripo.s.sol";
import {Resolver} from "../src/Resolver.sol";

/// @notice Separate lifecycle-v1 deployment. Existing demo custody and markets are not upgraded.
contract DeployTenderlyLifecycle is PripoDeployment {
    function run() external {
        require(block.chainid == 999143 && vm.envBool("TENDERLY_SINGLE_ACCOUNT_DEMO"), "isolated demo only");
        address sender = vm.envAddress("DEPLOYER");
        require(sender == address(0xA11CE), "wrong demo sender");
        Config memory c = _config(vm.readFile(vm.envString("DEPLOY_CONFIG")));
        c.governor = sender;
        c.guardian = sender;
        c.treasury = sender;
        Deployment memory d = _deploy(c, sender);
        // Distinct impersonated addresses for the fork demo; not independent production council operators.
        address[5] memory members = [address(0xA11C1), address(0xA11C2), address(0xA11C3), address(0xA11C4), address(0xA11C5)];
        vm.startBroadcast(sender);
        Resolver resolver = new Resolver(d.factory, members);
        vm.stopBroadcast();
        _writeManifest(c, d, sender, vm.envString("DEPLOY_OUTPUT"));
        string memory key = "lifecycle";
        vm.serializeAddress(key, "resolver", address(resolver));
        vm.serializeBytes32(key, "runtimeCodeHash", address(resolver).codehash);
        address[] memory council = new address[](5);
        for (uint256 i; i < 5; ++i) {
            council[i] = members[i];
        }
        string memory json = vm.serializeAddress(key, "council", council);
        vm.writeJson(json, "reports/deployment/resolver.json");
    }
}
