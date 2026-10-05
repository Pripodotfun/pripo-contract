// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoDeployment} from "../../script/DeployPripo.s.sol";

contract DeploymentHarness is PripoDeployment {
    function parseConfig(string memory json) external view returns (Config memory) {
        return _config(json);
    }

    function deploy(Config memory c, address sender) external returns (Deployment memory) {
        return _deploy(c, sender);
    }

    function configureDeployment(Config memory c, Deployment memory d) external {
        _configure(c, d);
    }

    function writeManifest(Config memory c, Deployment memory d, address sender, string memory path) external {
        _writeManifest(c, d, sender, path);
    }

    function readManifest() external view returns (Config memory c, Deployment memory d) {
        (c, d) = _readManifest();
        _verify(c, d);
    }
}
