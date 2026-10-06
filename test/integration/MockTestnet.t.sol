// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DeployMockTestnet} from "../../script/DeployMockTestnet.s.sol";
import {PripoDeployment} from "../../script/DeployPripo.s.sol";
import {TestnetMockUSDC} from "../../script/testnet/MockUSDC.sol";
import {DeploymentHarness} from "../helpers/DeploymentHarness.sol";
import {MockPyth} from "../helpers/MockPyth.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract MockTestnetTest is Test {
    function testReuseVerifiedCodeAndFundExactMockReserve() public {
        vm.chainId(10143);
        address sender = vm.addr(1);
        DeploymentHarness harness = new DeploymentHarness();
        PripoDeployment.Config memory c = PripoDeployment.Config(
            10143, address(new MockUSDC()), address(new MockPyth()), sender, sender, sender, 3, 300, true
        );
        PripoDeployment.Deployment memory original = harness.deploy(c, sender);
        harness.configureDeployment(c, original);
        uint256 originalDeadline = original.factory.adapterReadyAt(address(original.pythAdapter));
        vm.createDir("reports/deployment/mock-test", true);
        string memory source = "reports/deployment/mock-test/source.json";
        string memory output = "reports/deployment/mock-test/manifest.json";
        harness.writeManifest(c, original, sender, source);
        vm.warp(block.timestamp + 1 hours);
        vm.setEnv("FUNDED_DEPLOYER_PRIVATE_KEY", vm.toString(uint256(1)));
        vm.setEnv("DEPLOYER", vm.toString(sender));
        vm.setEnv("DEPLOY_OUTPUT", source);
        vm.setEnv("MOCK_DEPLOY_OUTPUT", output);
        PripoDeployment.Deployment memory d = new DeployMockTestnet().run();
        TestnetMockUSDC token = TestnetMockUSDC(address(d.vault.token()));
        assertEq(token.name(), "Pripo Mock USDC");
        assertEq(token.symbol(), "mUSDC");
        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(address(d.vault)), 10_000e6);
        assertEq(d.vault.protocolReserve(), 10_000e18);
        assertEq(d.vault.reserveFloor(), 10_000e18);
        assertEq(token.balanceOf(sender), 90_000e6);
        assertEq(token.allowance(sender, address(d.vault)), 0);
        assertEq(address(d.implementation), address(original.implementation));
        assertEq(address(d.market), address(original.market));
        assertEq(address(d.pythAdapter), address(original.pythAdapter));
        assertEq(address(original.vault.token()), c.usdc);
        assertEq(original.vault.protocolReserve(), 0);
        assertTrue(d.vault.registrars(address(d.factory)));
        assertEq(address(d.vault.backstopController()), address(d.backstop));
        assertEq(d.factory.adapterReadyAt(address(d.pythAdapter)), originalDeadline + 1 hours);
        assertFalse(d.factory.allowedAdapters(address(d.pythAdapter)));
        vm.setEnv("DEPLOY_OUTPUT", output);
        (PripoDeployment.Config memory saved, PripoDeployment.Deployment memory verified) = harness.readManifest();
        assertEq(saved.usdc, address(token));
        assertEq(address(verified.vault), address(d.vault));
        address trader = makeAddr("demo-trader");
        vm.startPrank(trader);
        token.faucet();
        token.approve(address(d.vault), 1_000e6);
        d.vault.deposit(1_000e6);
        assertEq(d.vault.freeBalance(trader), 1_000e18);
        d.vault.withdraw(1_000e6);
        vm.stopPrank();
        assertEq(token.balanceOf(trader), 10_000e6);
        assertEq(token.balanceOf(address(d.vault)), 10_000e6);
        assertEq(d.vault.protocolReserve(), 10_000e18);
    }

    function testMockDeploymentAndFaucetRejectMainnet() public {
        vm.chainId(143);
        vm.expectRevert("testnet only");
        new TestnetMockUSDC(address(this));
        DeployMockTestnet script = new DeployMockTestnet();
        vm.expectRevert("testnet only");
        script.run();
        vm.chainId(10143);
        TestnetMockUSDC token = new TestnetMockUSDC(address(this));
        vm.chainId(143);
        vm.expectRevert("testnet only");
        token.faucet();
    }
}
