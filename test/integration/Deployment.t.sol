// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConfigurePripo, PripoDeployment} from "../../script/DeployPripo.s.sol";
import {InsuranceBackstop} from "../../src/InsuranceBackstop.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {DeploymentHarness} from "../helpers/DeploymentHarness.sol";
import {MockPyth} from "../helpers/MockPyth.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract DeploymentTest is Test {
    DeploymentHarness internal script;
    PripoDeployment.Config internal config;
    address internal deployer;

    function setUp() public {
        vm.chainId(10143);
        script = new DeploymentHarness();
        deployer = makeAddr("deployer");
        config = PripoDeployment.Config(
            10143,
            address(new MockUSDC()),
            address(new MockPyth()),
            makeAddr("governor"),
            makeAddr("guardian"),
            makeAddr("treasury"),
            3,
            300,
            true
        );
    }

    function testFinalRolesAtomicInitializationAndResumableGovernance() public {
        PripoDeployment.Deployment memory d = script.deploy(config, deployer);
        assertEq(d.vault.governor(), config.governor);
        assertEq(d.vault.guardian(), config.guardian);
        assertEq(d.vault.treasury(), config.treasury);
        assertFalse(d.vault.registrars(deployer));
        assertFalse(d.vault.registrars(address(script)));
        assertFalse(d.vault.registrars(address(d.factory)));
        assertEq(d.vault.protocolReserve(), 0);
        vm.expectRevert();
        d.vault.initialize(config.usdc, deployer, deployer, deployer);
        vm.expectRevert();
        d.implementation.initialize(config.usdc, deployer, deployer, deployer);
        vm.prank(deployer);
        vm.expectRevert(E.Unauthorized.selector);
        d.vault.setRegistrar(deployer, true);

        // An interrupted Governor batch can resume without replacing the one-time backstop binding.
        vm.prank(config.governor);
        d.vault.setBackstopController(d.backstop);
        script.configureDeployment(config, d);
        assertEq(address(d.vault.backstopController()), address(d.backstop));
        assertTrue(d.vault.registrars(address(d.factory)));
        uint256 deadline = d.factory.adapterReadyAt(address(d.pythAdapter));
        assertEq(deadline, block.timestamp + 1 days);
        vm.warp(block.timestamp + 12 hours);
        script.configureDeployment(config, d);
        assertEq(d.factory.adapterReadyAt(address(d.pythAdapter)), deadline);
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        d.factory.activateAdapter(address(d.pythAdapter));
        vm.warp(deadline);
        d.factory.activateAdapter(address(d.pythAdapter));
        script.configureDeployment(config, d);
        assertTrue(d.factory.allowedAdapters(address(d.pythAdapter)));
        assertEq(d.factory.adapterReadyAt(address(d.pythAdapter)), 0);
    }

    function testRejectsWrongNetworkRolesDependenciesAndTimingBeforeCreation() public {
        uint64 nonce = vm.getNonce(deployer);
        config.chainId = 143;
        vm.expectRevert("wrong chain");
        script.deploy(config, deployer);
        config.chainId = 1;
        vm.expectRevert("unsupported network");
        script.deploy(config, deployer);
        config.chainId = 10143;
        address governor = config.governor;
        config.governor = address(0);
        vm.expectRevert("missing role");
        script.deploy(config, deployer);
        config.governor = governor;
        address usdc = config.usdc;
        config.usdc = makeAddr("no-code");
        vm.expectRevert("missing dependency");
        script.deploy(config, deployer);
        config.usdc = usdc;
        config.maxUpdateAgeSeconds = 4;
        vm.expectRevert("unsupported oracle timing");
        script.deploy(config, deployer);
        config.maxUpdateAgeSeconds = 3;
        vm.mockCall(usdc, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert("USDC decimals");
        script.deploy(config, deployer);
        assertEq(vm.getNonce(deployer), nonce);
    }

    function testRejectsMismatchedRolesAndConflictingBackstop() public {
        PripoDeployment.Deployment memory d = script.deploy(config, deployer);
        address governor = config.governor;
        config.governor = deployer;
        vm.expectRevert("wrong governor");
        script.configureDeployment(config, d);
        config.governor = governor;
        InsuranceBackstop other = new InsuranceBackstop(address(d.vault));
        vm.prank(governor);
        d.vault.setBackstopController(other);
        vm.expectRevert("unexpected backstop");
        script.configureDeployment(config, d);
        assertFalse(d.vault.registrars(address(d.factory)));
        assertEq(d.factory.adapterReadyAt(address(d.pythAdapter)), 0);
    }

    function testManifestRoundTripAndTamperedRuntimeRejected() public {
        PripoDeployment.Deployment memory d = script.deploy(config, deployer);
        vm.createDir("reports/deployment", true);
        string memory path = "reports/deployment/unit-manifest.json";
        script.writeManifest(config, d, deployer, path);
        vm.setEnv("DEPLOY_OUTPUT", path);
        (PripoDeployment.Config memory c, PripoDeployment.Deployment memory loaded) = script.readManifest();
        assertEq(c.chainId, 10143);
        assertEq(address(loaded.vault), address(d.vault));
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddressArray(json, ".contracts").length, 19);
        address[] memory targets = vm.parseJsonAddressArray(json, ".governanceTargets");
        bytes[] memory calls = vm.parseJsonBytesArray(json, ".governanceCalldata");
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(c.governor);
            (bool success,) = targets[i].call(calls[i]);
            assertTrue(success);
        }
        assertTrue(d.vault.registrars(address(d.factory)));
        assertEq(address(d.vault.backstopController()), address(d.backstop));
        assertEq(d.factory.adapterReadyAt(address(d.pythAdapter)), block.timestamp + 1 days);
        ConfigurePripo governorScript = new ConfigurePripo();
        governorScript.configure();
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        governorScript.activate();
        vm.warp(block.timestamp + 1 days);
        governorScript.activate();
        assertTrue(d.factory.allowedAdapters(address(d.pythAdapter)));
        vm.etch(address(d.market), hex"00");
        vm.expectRevert("runtime mismatch");
        script.readManifest();
    }
}
