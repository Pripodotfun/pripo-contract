// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract SettlementGasTest is MarketFixture {
    address[127] private accounts;

    function setUp() public {
        _setup(false);
        _open(alice, 10e18);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = address(uint160(0x10000 + i));
            _deposit(accounts[i], 20e6);
            _open(accounts[i], i % 2 == 0 ? -int256(0.1e18) : int256(0.1e18));
        }
        vm.roll(block.number + 50_000_000);
    }

    function testWholeBookSettlementAt128Positions() public {
        assertEq(market.positionCount(), 128);
        uint256 gasBefore = gasleft();
        market.liquidate(alice, "");
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("128-position liquidation and terminal settlement gas", used);
        assertLt(used, 20_000_000, "local gross execution gas budget; target-chain fork validation still required");
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Settled));
        assertEq(market.positionCount(), 0);
        assertEq(market.longSize() + market.shortSize(), 0);
        T.Ledger memory l = vault.ledger(address(market));
        assertEq(l.clearing, 0);
        assertEq(l.fundingPool, 0);
        int256 cash = int256(
            vault.freeBalance(alice) + vault.freeBalance(bob) + vault.freeBalance(carol) + vault.freeBalance(creator)
                + vault.protocolReserve() + l.insurance + l.creatorOwed + l.protocolOwed
        ) - int256(vault.deficit(address(market)));
        assertEq(vault.locked(alice, address(market)), 0);
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(vault.locked(accounts[i], address(market)), 0);
            assertEq(market.position(accounts[i]).size, 0);
            cash += int256(vault.freeBalance(accounts[i]));
        }
        assertEq(cash, int256(usdc.balanceOf(address(vault)) * 1e12));
    }
}

contract AdlGasTest is MarketFixture {
    address[126] private accounts;

    function setUp() public {
        _setup(false);
        _open(alice, 10e18);
        _open(carol, 10e18);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = address(uint160(0x20000 + i));
            _deposit(accounts[i], 300e6);
            _open(accounts[i], -int256(0.08e18));
        }
        vm.roll(block.number + 10_000_000);
        _close(carol, 0.999e18);
        vm.roll(block.number + 300);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 margin = vault.locked(alice, address(market)) - owed;
        int256 desired = -int256(vault.ledger(address(market)).insurance) + 0.5e18;
        vm.prank(alice);
        market.addMargin(uint256(desired - margin));
        // Larger early margins reverse most score ordering relative to book insertion order.
        for (uint256 i; i < accounts.length; ++i) {
            vm.prank(accounts[i]);
            market.addMargin((accounts.length - i) * 2e18);
        }
    }

    function testPairedAdlAcross125WinnersAtPositionLimit() public {
        assertEq(market.positionCount(), 128);
        T.AmmState memory beforeAmm = market.ammState();
        uint256 gasBefore = gasleft();
        market.liquidate(alice, "");
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("128-position book with 125 paired winners gas", used);
        assertLt(used, 20_000_000);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
        assertEq(market.positionCount(), 2);
        assertEq(market.ammState().baseReserve, beforeAmm.baseReserve);
        assertEq(market.ammState().quoteReserve, beforeAmm.quoteReserve);
        T.Ledger memory l = vault.ledger(address(market));
        int256 cash = int256(
            vault.freeBalance(alice) + vault.freeBalance(bob) + vault.freeBalance(carol) + vault.freeBalance(creator)
                + vault.protocolReserve() + l.insurance + l.creatorOwed + l.protocolOwed
        ) + vault.locked(carol, address(market)) + l.clearing + l.fundingPool;
        for (uint256 i; i < accounts.length; ++i) {
            cash += int256(vault.freeBalance(accounts[i])) + vault.locked(accounts[i], address(market));
        }
        assertEq(cash, int256(usdc.balanceOf(address(vault)) * 1e12));
    }
}
