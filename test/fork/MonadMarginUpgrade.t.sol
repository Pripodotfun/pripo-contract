// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarginVault} from "../../src/MarginVault.sol";
import {Market} from "../../src/Market.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {Test} from "forge-std/Test.sol";

contract MonadMarginUpgradeTest is Test {
    function testTestnetUpgradeDelayCreationAndMarginEntry() public {
        if (!vm.envOr("MARGIN_UPGRADE_FORK", false)) vm.skip(true);
        vm.createSelectFork("monad_testnet", vm.envUint("MARGIN_UPGRADE_BLOCK"));
        assertEq(block.chainid, 10143);
        MarketFactory factory = MarketFactory(0x133A614CBE2CBA1789E67E0898C0F5c56Eb7BBf0);
        MarginVault vault = MarginVault(0x1980B3a41393f610a8BE552C71BAE3F42AAB6735);
        Market legacy = Market(0xeA326A40694dA4D7C5c64719B48Ba561EcA8C0Eb);
        address sender = vault.governor();
        bytes32 legacyCode = address(legacy).codehash;
        int256 legacySize = legacy.position(sender).size;
        uint256 reserve = vault.protocolReserve();
        Market implementation = new Market();
        assertEq(factory.pendingImplementation(), address(0));
        vm.prank(sender);
        factory.scheduleImplementation(address(implementation));
        uint256 ready = factory.implementationReadyAt();
        assertEq(ready, block.timestamp + 1 days);
        vm.warp(ready - 1);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.GovernanceNotReady.selector, ready));
        factory.activateImplementation();
        vm.warp(ready);
        factory.activateImplementation();
        T.CreateParams memory params =
            T.CreateParams("PRIPO:DEMO-V2", factory.nullAdapter(), bytes32(0), 100e18, 200_000e18, 2_000e6);
        vm.startPrank(sender);
        vault.token().approve(address(factory), 2_000e6);
        Market market = Market(factory.createMarket(params));
        vault.token().approve(address(vault), 100e6);
        vault.deposit(100e6);
        uint256 free = vault.freeBalance(sender);
        T.MarginOpenQuote memory q = market.quoteOpenWithMargin(sender, true, 50e18, 2);
        T.MarginOpenResult memory result = market.openWithMargin(true, 50e18, 2, 101e18, "");
        assertEq(market.marginEntryVersion(), 1);
        assertEq(market.position(sender).margin, 50e18);
        assertEq(market.position(sender).size, q.size);
        assertEq(market.position(sender).entryCost, q.notional);
        assertEq(free - vault.freeBalance(sender), 50e18 + q.fee);
        (int256 health, bool liquidatable) = market.health(sender);
        assertEq(result.healthWad, health);
        assertEq(result.liquidatable, liquidatable);
        market.close(1e18, 99e18, "");
        vm.stopPrank();
        assertEq(market.position(sender).size, 0);
        assertEq(address(legacy).codehash, legacyCode);
        assertEq(legacy.position(sender).size, legacySize);
        assertEq(vault.protocolReserve(), reserve);
        assertEq(address(market.vault()), address(vault));
    }
}
