// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployPripo, PripoDeployment} from "../../script/DeployPripo.s.sol";
import {ConfigureRehearsalSafes, CreateRehearsalSafes, IRehearsalSafe} from "../../script/RehearsalSafes.s.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {Test} from "forge-std/Test.sol";

contract MonadRehearsalSafesTest is Test {
    function testRealSafeFactoryThresholdsAndSignedGovernorWiring() public {
        vm.skip(!vm.envOr("MONAD_FORK_ENABLED", false), "Enable the Monad fork profile");
        string memory report = vm.readFile("reports/monad/preflight.json");
        vm.createSelectFork("monad", vm.parseJsonUint(report, ".updateFork.block"));
        assertEq(block.chainid, 143);
        // This local regression models the custom chain ID; the hosted Tenderly rehearsal is a separate run.
        vm.chainId(999143);
        vm.createDir("reports/deployment", true);
        vm.setEnv("DEPLOY_CONFIG", "reports/deployment/safe-test-config.json");
        vm.setEnv("DEPLOY_OUTPUT", "reports/deployment/safe-test-manifest.json");
        vm.setEnv("DEPLOYER", vm.toString(makeAddr("safe-deployer")));
        vm.setEnv("REHEARSAL_SAFE_SALT", "1");
        CreateRehearsalSafes create = new CreateRehearsalSafes();
        create.run();
        string memory config = vm.readFile("reports/deployment/safe-test-config.json");
        address governor = vm.parseJsonAddress(config, ".governor");
        address guardian = vm.parseJsonAddress(config, ".guardian");
        address treasury = vm.parseJsonAddress(config, ".treasury");
        address council = vm.parseJsonAddress(config, ".council");
        assertEq(IRehearsalSafe(governor).getOwners().length, 5);
        assertEq(IRehearsalSafe(governor).getThreshold(), 3);
        assertEq(IRehearsalSafe(guardian).getOwners().length, 3);
        assertEq(IRehearsalSafe(guardian).getThreshold(), 2);
        assertEq(IRehearsalSafe(treasury).getThreshold(), 3);
        assertEq(IRehearsalSafe(council).getThreshold(), 3);
        assertNotEq(governor, council);
        assertNotEq(governor, treasury);

        DeployPripo deploy = new DeployPripo();
        PripoDeployment.Deployment memory d = deploy.run();
        assertEq(d.vault.governor(), governor);
        assertEq(d.vault.guardian(), guardian);
        assertEq(d.vault.treasury(), treasury);
        bytes memory unauthorized = abi.encodeCall(MarginVault.setRegistrar, (address(this), true));
        vm.expectRevert("GS020");
        IRehearsalSafe(governor)
            .execTransaction(address(d.vault), 0, unauthorized, 0, 0, 0, 0, address(0), payable(address(0)), "");
        assertFalse(d.vault.registrars(address(this)));
        ConfigureRehearsalSafes wire = new ConfigureRehearsalSafes();
        wire.run();
        assertEq(IRehearsalSafe(governor).nonce(), 3);
        assertEq(address(d.vault.backstopController()), address(d.backstop));
        assertTrue(d.vault.registrars(address(d.factory)));
        assertEq(d.factory.adapterReadyAt(address(d.pythAdapter)), block.timestamp + 1 days);
        assertFalse(d.factory.allowedAdapters(address(d.pythAdapter)));
        vm.chainId(143);
        vm.expectRevert("rehearsal chain only");
        create.run();
        vm.expectRevert("rehearsal chain only");
        wire.run();
    }
}
