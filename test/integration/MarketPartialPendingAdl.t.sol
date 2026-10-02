// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract MarketPartialPendingAdlTest is MarketFixture {
    function setUp() public {
        _setup(true);
    }

    function _config(bool externalIndex) internal view override returns (T.MarketConfig memory c) {
        c = super._config(externalIndex);
        c.degradeAfterBlocks = 400_000_000;
    }

    function testNegativeCollateralIsLiquidatableAboveMaintenanceHealth() public {
        address[] memory users = new address[](16);
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(uint160(0xa000 + i));
            _deposit(users[i], 1_000e6);
            _open(users[i], -15e18);
        }
        _open(alice, 1e18);
        for (uint256 i; i < users.length; ++i) {
            _close(users[i], 1e18);
        }
        for (uint256 i; i < users.length; ++i) {
            _open(users[i], 15e18);
        }
        vm.roll(block.number + 300);
        source.set(market.markPrice(), uint64(block.number), 0);
        market.remark();
        // Isolate the liquidation predicate with a balanced funding debit. Trading/price state comes from fills.
        int256 debit = vault.locked(alice, address(market)) + 1;
        vm.prank(address(market));
        vault.settleFunding(alice, debit);
        (int256 health, bool liquidatable) = market.health(alice);
        assertGt(health, int256(uint256(market.config().mmrBps) * 1e14));
        assertTrue(liquidatable);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 0);
        _assertCashWith(users);
    }

    function testPartialPendingUsesOriginalEntryScheduleAndRetainsUnselectedFundingDebt() public {
        _preparePartialDebt(2, 1, 0.5e18);
        uint256 originalEntry = market.position(alice).entryCost;
        uint256 free = vault.freeBalance(alice);
        address[] memory list = new address[](1);
        list[0] = bob;
        market.liquidate(alice, "", list);
        T.AdlPending memory p = market.pendingAdl(alice);
        assertEq(p.S0, 5e18);
        assertEq(p.E0, originalEntry / 2);
        assertEq(p.matchedSize, 3e18);
        assertEq(market.position(alice).entryCost, originalEntry - p.E0 * 3 / 5);
        assertEq(vault.freeBalance(alice), free);
        assertLt(vault.locked(alice, address(market)), 0);
        _assertCash();
        vm.roll(block.number + 1_000);
        list[0] = creator;
        market.continueAdl(alice, list);
        assertFalse(market.pendingAdl(alice).active);
        assertEq(market.position(alice).size, 5e18);
        assertEq(market.position(alice).entryCost, originalEntry - p.E0);
        assertEq(vault.freeBalance(alice), free);
        assertLt(vault.locked(alice, address(market)), 0);
        assertEq(vault.adlReservedTotal(address(market)), 0);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Degraded));
        _assertCash();
    }

    function testCoveredPartialUsesAllocatedDebtAndDoesNotCreateInvalidAdlValue() public {
        _preparePartialDebt(6, 5, 0);
        int256 beforeMargin = vault.locked(alice, address(market));
        assertLt(beforeMargin, -int256(vault.ledger(address(market)).insurance));
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 5e18);
        assertFalse(market.pendingAdl(alice).active);
        assertEq(vault.locked(alice, address(market)), beforeMargin / 2);
        assertEq(vault.adlReservedTotal(address(market)), 0);
        _assertCash();
    }

    function _preparePartialDebt(uint256 numerator, uint256 denominator, int256 offset) internal {
        _deposit(alice, 30_000e6);
        _open(alice, 10e18);
        _open(carol, 10e18);
        _open(bob, -3e18);
        _open(creator, -17e18);
        _open(carol, 1e18);
        source.set(90e18, uint64(block.number), 0);
        market.remark();
        vm.roll(block.number + 400_000_001);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 600);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 current = vault.locked(alice, address(market)) - owed;
        int256 desired = -int256(vault.ledger(address(market)).insurance * numerator / denominator) + offset;
        assertLt(current, desired);
        vm.prank(alice);
        market.addMargin(uint256(desired - current));
    }
}
