// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CreateDemoMarket} from "../../script/CreateDemoMarket.s.sol";
import {DeployMockTestnet} from "../../script/DeployMockTestnet.s.sol";
import {PripoDeployment} from "../../script/DeployPripo.s.sol";
import {OpenDemoPosition} from "../../script/OpenDemoPosition.s.sol";
import {TestnetMockUSDC} from "../../script/testnet/MockUSDC.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
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
        vm.setEnv("DEMO_MARKET_OUTPUT", "reports/deployment/mock-test/demo-market.json");
        CreateDemoMarket creator = new CreateDemoMarket();
        Market market = creator.run();
        assertEq(d.factory.marketCount(), 1);
        assertEq(d.factory.marketForSymbol(keccak256("PRIPO:DEMO")), address(market));
        assertEq(token.balanceOf(sender), 88_000e6);
        assertEq(token.balanceOf(address(d.vault)), 12_000e6);
        assertEq(token.balanceOf(address(d.factory)), 0);
        assertEq(d.vault.freeBalance(address(d.factory)), 0);
        assertEq(d.vault.protocolReserve(), 10_000e18);
        assertEq(d.vault.ledger(address(market)).insurance, 2_000e18);
        assertEq(market.config().maxLeverageX, 2);
        assertEq(market.positionCount(), 0);
        assertEq(token.allowance(sender, address(d.factory)), 0);
        vm.expectRevert("demo already created");
        creator.run();
        assertEq(token.balanceOf(sender), 88_000e6);
        vm.setEnv("DEMO_MARKET_INPUT", "reports/deployment/mock-test/demo-market.json");
        vm.setEnv("DEMO_POSITION_OUTPUT", "reports/deployment/mock-test/position.json");
        OpenDemoPosition opener = new OpenDemoPosition();
        (uint256 average, uint256 fee, uint256 margin,) = market.quoteOpenFor(sender, 1e18);
        opener.run();
        assertEq(market.position(sender).size, 1e18);
        assertEq(market.position(sender).entryCost, average);
        assertEq(d.vault.locked(sender, address(market)), int256(margin));
        assertEq(d.vault.freeBalance(sender), 100e18 - margin - fee);
        assertEq(token.balanceOf(sender), 87_900e6);
        assertEq(token.balanceOf(address(d.vault)), 12_100e6);
        assertEq(d.vault.protocolReserve(), 10_000e18);
        assertEq(token.allowance(sender, address(d.vault)), 0);
        vm.expectRevert("position already exists");
        opener.run();
        assertEq(token.balanceOf(sender), 87_900e6);
        // A first-time trader must reject an adverse quote before approving or depositing tokens.
        vm.setEnv("FUNDED_DEPLOYER_PRIVATE_KEY", vm.toString(uint256(2)));
        vm.setEnv("DEPLOYER", vm.toString(vm.addr(2)));
        _moveDemoPriceAboveLimit(market, token, address(d.vault));
        vm.expectRevert("quote exceeds limit");
        opener.run();
    }

    function testMockDeploymentAndFaucetRejectMainnet() public {
        vm.chainId(143);
        vm.expectRevert("testnet only");
        new TestnetMockUSDC(address(this));
        DeployMockTestnet script = new DeployMockTestnet();
        vm.expectRevert("testnet only");
        script.run();
        CreateDemoMarket creator = new CreateDemoMarket();
        vm.expectRevert("testnet only");
        creator.run();
        OpenDemoPosition opener = new OpenDemoPosition();
        vm.expectRevert("testnet only");
        opener.run();
        vm.chainId(10143);
        TestnetMockUSDC token = new TestnetMockUSDC(address(this));
        vm.chainId(143);
        vm.expectRevert("testnet only");
        token.faucet();
    }

    function _moveDemoPriceAboveLimit(Market market, TestnetMockUSDC token, address vaultAddress) internal {
        address trader = makeAddr("price-mover");
        vm.startPrank(trader);
        token.faucet();
        token.approve(vaultAddress, 1_000e6);
        MarginVault(vaultAddress).deposit(1_000e6);
        market.open(10e18, 102e18, "");
        vm.stopPrank();
    }
}
