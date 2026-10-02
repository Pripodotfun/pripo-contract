// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeeSweeper} from "../../src/FeeSweeper.sol";
import {Market} from "../../src/Market.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";

contract FeeSweeperTest is MarketFixture {
    FeeSweeper private sweeper;
    Market private other;
    address[] private tracked;

    function setUp() public {
        _setup(false);
        other = _newMarket(false);
        sweeper = new FeeSweeper(IMarginVault(address(vault)));
        tracked.push(address(market));
        tracked.push(address(other));
    }

    function testBatchSweepsActualTradingFeesAndRetainsTokenDust() public {
        _open(alice, 3e18 + 1);
        vm.prank(bob);
        other.open(-2e18 - 1, 0, "");
        uint256 first = vault.ledger(address(market)).protocolOwed;
        uint256 second = vault.ledger(address(other)).protocolOwed;
        uint256 expected = (first / 1e12 + second / 1e12) * 1e12;
        vm.prank(carol);
        (uint256 repaid, uint256 reserved, uint256 paid) = sweeper.sweep(_batch());
        assertEq(repaid + reserved, 0);
        assertEq(paid, expected);
        assertEq(usdc.balanceOf(treasury) * 1e12, paid);
        assertEq(vault.ledger(address(market)).protocolOwed, first % 1e12);
        assertEq(vault.ledger(address(other)).protocolOwed, second % 1e12);
        assertEq(vault.protocolReserve(), vault.reserveFloor());
        _cash();
    }

    function testIncompleteRecoveryPersistsThenWholeBatchAllocatesBeforePayout() public {
        _terminal(10_100e18);
        assertEq(vault.totalDeficit(), 100e18);
        _fees(address(market), 60e18);
        _fees(address(other), 50e18);
        (uint256 repaid, uint256 reserved, uint256 paid) = sweeper.sweep(_batch());
        assertEq(repaid, 100e18);
        assertEq(reserved, 10e18);
        assertEq(paid, 0);
        assertEq(vault.totalDeficit(), 0);
        assertEq(vault.protocolReserve(), 10e18);
        _fees(address(market), 10_000e18);
        (repaid, reserved, paid) = sweeper.sweep(_batch());
        assertEq(repaid, 0);
        assertEq(reserved, 9_990e18);
        assertEq(paid, 10e18);
        assertEq(usdc.balanceOf(treasury), 10e6);
        _cash();
    }

    function testBoundedAllocationLeavesQueueAndFeesForNextCall() public {
        address first = _terminal(10_000e18 + 1);
        address second = _terminal(1);
        _fees(address(market), 3);
        address[] memory batch = new address[](1);
        batch[0] = address(market);
        (uint256 repaid, uint256 reserved) = sweeper.allocate(batch, 1);
        assertEq(repaid, 1);
        assertEq(reserved, 0);
        assertEq(vault.totalDeficit(), 1);
        assertEq(vault.deficit(first) + vault.deficit(second), 1);
        assertEq(vault.ledger(address(market)).protocolOwed, 2);
        (repaid, reserved) = sweeper.allocate(batch, 1);
        assertEq(repaid, 1);
        assertEq(reserved, 1);
        assertEq(usdc.balanceOf(treasury), 0);
        _cash();
    }

    function testInvalidBatchesAndBudgetsRejectBeforeAnyAllocation() public {
        _terminal(10_001e18);
        _fees(address(market), 1e18);
        address[] memory batch = _batch();
        batch[1] = address(0xbeef);
        vm.expectRevert(E.Unauthorized.selector);
        sweeper.sweep(batch);
        batch[1] = batch[0];
        vm.expectRevert(E.InvalidConfiguration.selector);
        sweeper.sweep(batch);
        vm.expectRevert(E.AllocationLimit.selector);
        sweeper.sweep(new address[](0));
        vm.expectRevert(E.AllocationLimit.selector);
        sweeper.sweep(new address[](33));
        vm.expectRevert(E.AllocationLimit.selector);
        sweeper.allocate(_batch(), 0);
        vm.expectRevert(E.AllocationLimit.selector);
        sweeper.allocate(_batch(), 33);
        assertEq(vault.totalDeficit(), 1e18);
        assertEq(vault.ledger(address(market)).protocolOwed, 1e18);
        vm.expectRevert(E.InvalidAddress.selector);
        new FeeSweeper(IMarginVault(address(0)));
        _cash();
    }

    function _batch() private view returns (address[] memory batch) {
        batch = new address[](2);
        batch[0] = address(market);
        batch[1] = address(other);
    }

    function _fees(address m, uint256 amount) private {
        vm.prank(m);
        vault.chargeFee(creator, T.FeeBreakdown(amount, amount, 0, 0, 0), false);
    }

    function _terminal(uint256 amount) private returns (address m) {
        TerminalMarketStub terminal = new TerminalMarketStub();
        m = address(terminal);
        tracked.push(m);
        vault.registerMarket(m, creator);
        // Balanced synthetic terminal boundary: a receiver has realized its funding before the payer settles.
        vm.startPrank(m);
        vault.settleFunding(alice, int256(amount));
        vault.settleFunding(bob, -int256(amount));
        vault.release(bob, amount);
        vm.stopPrank();
        terminal.setState(T.Status.Settled, 0, 0);
        address[] memory debtors = new address[](1);
        debtors[0] = alice;
        vm.prank(m);
        vault.finalizeSettlement(debtors);
    }

    function _cash() private view {
        int256 total = int256(
            vault.freeBalance(alice) + vault.freeBalance(bob) + vault.freeBalance(carol) + vault.freeBalance(creator)
                + vault.protocolReserve() + vault.backstopBalance()
        ) - int256(vault.totalDeficit());
        for (uint256 i; i < tracked.length; ++i) {
            T.Ledger memory l = vault.ledger(tracked[i]);
            total += int256(l.protocolOwed + l.creatorOwed + l.insurance + l.skewPool) + l.clearing + l.fundingPool;
            total += vault.locked(alice, tracked[i]) + vault.locked(bob, tracked[i]) + vault.locked(carol, tracked[i])
            + vault.locked(creator, tracked[i]);
        }
        assertEq(total, int256(usdc.balanceOf(address(vault)) * 1e12));
    }
}
