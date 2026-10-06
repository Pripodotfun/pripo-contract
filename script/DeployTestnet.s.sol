// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoDeployment} from "./DeployPripo.s.sol";

abstract contract TestnetDeployment is PripoDeployment {
    function _signer() internal returns (address sender) {
        require(block.chainid == 10143, "testnet only");
        sender = vm.rememberKey(vm.envUint("FUNDED_DEPLOYER_PRIVATE_KEY"));
        require(sender == vm.envAddress("DEPLOYER"), "wrong signer");
    }
}

/// @notice Testnet signing entry point for the shared production deployment sequence.
contract DeployTestnet is TestnetDeployment {
    function run() external returns (Deployment memory d) {
        require(block.chainid == 10143, "testnet only");
        Config memory c = _config(vm.readFile(vm.envString("DEPLOY_CONFIG")));
        require(c.chainId == 10143, "wrong testnet config");
        address sender = _signer();
        d = _deploy(c, sender);
        _writeManifest(c, d, sender, vm.envString("DEPLOY_OUTPUT"));
    }
}

contract ConfigureTestnet is TestnetDeployment {
    function configure() external {
        require(block.chainid == 10143, "testnet only");
        (Config memory c, Deployment memory d) = _readManifest();
        require(c.governor == _signer(), "Governor requires separate signatures");
        _configure(c, d);
    }

    function activate() external {
        require(block.chainid == 10143, "testnet only");
        (Config memory c, Deployment memory d) = _readManifest();
        _verify(c, d);
        uint256 ready = d.factory.adapterReadyAt(address(d.pythAdapter));
        require(ready != 0 && block.timestamp >= ready, "approval delay not elapsed");
        vm.startBroadcast(_signer());
        d.factory.activateAdapter(address(d.pythAdapter));
        vm.stopBroadcast();
    }
}
