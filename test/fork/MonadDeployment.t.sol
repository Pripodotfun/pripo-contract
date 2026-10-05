// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoDeployment} from "../../script/DeployPripo.s.sol";
import {Market} from "../../src/Market.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {DeploymentHarness} from "../helpers/DeploymentHarness.sol";
import {MonadSignedPythFixture} from "./MonadSignedPyth.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Rehearse the deployment implementation with native dependencies and a real elapsed approval delay.
contract MonadDeploymentTest is MonadSignedPythFixture {
    function testDeploymentGovernanceReserveSignedMarketAndWithdrawal() public {
        uint256 currentFork = vm.activeFork();
        uint256 currentTime = vm.getBlockTimestamp();
        vm.createSelectFork("monad", vm.parseJsonUint(report, ".governanceFork.block"));
        assertEq(vm.getBlockTimestamp(), vm.parseJsonUint(report, ".governanceFork.timestamp"));
        DeploymentHarness script = new DeploymentHarness();
        PripoDeployment.Config memory c = PripoDeployment.Config(
            143,
            vm.parseJsonAddress(config, ".usdc"),
            address(provider),
            makeAddr("deployment-governor"),
            makeAddr("deployment-guardian"),
            makeAddr("deployment-treasury"),
            3,
            300,
            true
        );
        PripoDeployment.Deployment memory d = script.deploy(c, makeAddr("deployment-sender"));
        script.configureDeployment(c, d);
        assertEq(d.vault.governor(), c.governor);
        assertEq(d.vault.guardian(), c.guardian);
        assertEq(d.vault.treasury(), c.treasury);
        assertEq(d.vault.protocolReserve(), 0);
        assertEq(address(d.vault.backstopController()), address(d.backstop));
        assertTrue(d.vault.registrars(address(d.factory)));
        vm.expectPartialRevert(MarketFactory.GovernanceNotReady.selector);
        d.factory.activateAdapter(address(d.pythAdapter));
        vm.makePersistent(address(d.implementation), address(d.vault), address(d.market));
        vm.makePersistent(address(d.nullAdapter), address(d.pythAdapter), address(d.factory));
        vm.makePersistent(address(d.backstop), address(d.sweeper));

        vm.selectFork(currentFork);
        assertEq(vm.getBlockTimestamp(), currentTime);
        assertGe(currentTime, d.factory.adapterReadyAt(address(d.pythAdapter)));
        d.factory.activateAdapter(address(d.pythAdapter));
        d.pythAdapter.getPrice{value: fee}(feed, abi.encode(updates));
        IERC20 usdc = IERC20(c.usdc);
        address creator = makeAddr("deployment-creator");
        address trader = makeAddr("deployment-trader");
        deal(c.usdc, creator, 5_500e6);
        deal(c.usdc, trader, 2_000e6);
        deal(c.usdc, address(this), 10_000e6);
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        usdc.approve(address(d.factory), 5_500e6);
        d.factory.listFeed(address(d.pythAdapter), feed);
        T.CreateParams memory params =
            T.CreateParams("DEPLOY-BTC", address(d.pythAdapter), feed, 1, 2_000_000e18, 5_000e6);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        d.factory.createMarket{value: fee}(params, abi.encode(updates));
        vm.stopPrank();
        usdc.approve(address(d.vault), 10_000e6);
        d.vault.fundProtocolReserve(10_000e6);
        vm.prank(creator);
        Market market = Market(d.factory.createMarket{value: fee}(params, abi.encode(updates)));
        assertEq(d.vault.ledger(address(market)).insurance, 5_000e18);
        assertEq(d.vault.protocolReserve(), 10_000e18);
        assertEq(usdc.balanceOf(address(d.vault)), 15_000e6);
        vm.startPrank(trader);
        usdc.approve(address(d.vault), 2_000e6);
        d.vault.deposit(2_000e6);
        assertGt(market.maxOpenable(trader, true), 0);
        market.open(1e15, type(uint256).max, "");
        market.close(1e18, 0, "");
        d.vault.withdraw(d.vault.freeBalance(trader) / 1e12);
        vm.stopPrank();
        address[] memory markets = new address[](1);
        markets[0] = address(market);
        d.sweeper.sweep(markets);
        T.Ledger memory ledger = d.vault.ledger(address(market));
        assertEq(market.positionCount(), 0);
        assertEq(d.vault.locked(trader, address(market)), 0);
        assertEq(ledger.clearing, 0);
        assertEq(ledger.fundingPool, 0);
        assertEq(
            usdc.balanceOf(address(d.vault)) * 1e12,
            d.vault.protocolReserve() + ledger.insurance + ledger.creatorOwed + ledger.protocolOwed
                + d.vault.freeBalance(trader)
        );
    }
}
