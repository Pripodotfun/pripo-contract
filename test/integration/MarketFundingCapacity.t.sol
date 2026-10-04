// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {RiskMath as Risk} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MarketFundingCapacityTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function testLongOutageClampsBothSidesAndReceiverWithdrawsFirstWithoutCapitalSupport() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        (int256 cap, uint256 protectedAmount, uint256 capacity) = market.fundingCapacity(alice);
        uint256 insurance = vault.ledger(address(market)).insurance;
        uint256 reserve = vault.protocolReserve();
        vm.roll(block.number + 100_000_000);
        assertEq(market.fundingState().longIndex, cap);
        assertEq(market.fundingBinding(), alice);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        assertGt(owed, 0);
        assertLe(uint256(owed), capacity);
        assertGe(vault.locked(alice, address(market)) - owed, int256(protectedAmount));
        _checkHeaps();
        _close(bob, 1e18);
        uint256 withdrawal = vault.freeBalance(bob) / 1e12;
        vm.prank(bob);
        vault.withdraw(withdrawal);
        assertEq(market.fundingBinding(), alice, "closing the counterparty cannot release the latch");
        _close(alice, 1e18);
        assertEq(market.fundingBinding(), address(0));
        assertGe(vault.ledger(address(market)).insurance, insurance, "only fees may increase insurance");
        assertEq(vault.protocolReserve(), reserve);
        assertEq(market.positionDebt(alice), 0);
        market.sweepFundingSurplus();
        _checkHeaps();
        _assertCash();
    }

    function testOnlyBindingTouchWithNewCapacityReleasesFreezeAndNeverCatchesUp() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 30_000_000);
        market.poke();
        T.FundingState memory frozen = market.fundingState();
        vm.roll(block.number + 30_000_000);
        vm.prank(bob);
        market.addMargin(1e18);
        _open(bob, -10e18); // The rate changes sign; the frozen indexes must not move.
        market.poke();
        market.remark();
        market.sweepFundingSurplus();
        assertEq(market.fundingBinding(), alice);
        assertEq(market.fundingRatePerBlock(), 0);
        assertEq(market.fundingState().longIndex, frozen.longIndex);
        assertEq(market.fundingState().shortIndex, frozen.shortIndex);
        vm.prank(alice);
        market.addMargin(1); // Less than one index quantum of new margin is not usable funding capacity.
        assertEq(market.fundingBinding(), alice);
        vm.prank(alice);
        market.addMargin(10e18);
        assertEq(market.fundingBinding(), address(0));
        assertEq(market.fundingState().longIndex, frozen.longIndex);
        assertEq(market.fundingState().shortIndex, frozen.shortIndex);
        assertEq(market.fundingState().lastBlock, block.number);
        assertLt(market.fundingRatePerBlock(), 0);
        _checkHeaps();
        _assertCash();
    }

    function testCapacityExhaustionMakesOtherwiseHealthyPayerLiquidatable() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 30_000_000);
        (int256 health, bool liquidatable) = market.health(alice);
        assertGt(health, 0.15e18);
        assertTrue(liquidatable);
        uint256 reserve = vault.protocolReserve();
        uint256 insurance = vault.ledger(address(market)).insurance;
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 0);
        assertEq(market.fundingBinding(), address(0));
        assertEq(vault.protocolReserve(), reserve);
        assertGe(vault.ledger(address(market)).insurance, insurance);
        _checkHeaps();
        _assertCash();
    }

    function testShortPayerCapacityAndHeapUpdatesAcrossMarginPartialCloseAndSlotReuse() public {
        _open(alice, -10e18);
        _open(bob, 1e18);
        vm.prank(alice);
        market.addMargin(100e18);
        _checkHeaps();
        vm.roll(block.number + 1_000_000_000);
        (int256 cap, uint256 protectedAmount, uint256 capacity) = market.fundingCapacity(alice);
        assertEq(market.fundingState().shortIndex, cap);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        assertLe(uint256(owed), capacity);
        assertGe(vault.locked(alice, address(market)) - owed, int256(protectedAmount));
        _close(alice, 0.5e18);
        _checkHeaps();
        vm.prank(alice);
        market.addMargin(200e18);
        vm.prank(alice);
        market.removeMargin(50e18);
        _checkHeaps();
        _close(alice, 1e18);
        _open(carol, -2e18);
        _checkHeaps();
        _assertCash();
    }

    function _checkHeaps() internal view {
        address[] memory users = market.positionAccounts(0, 128);
        for (uint256 side; side < 2; ++side) {
            address expected;
            int256 minIndex = type(int256).max;
            for (uint256 i; i < users.length; ++i) {
                T.Position memory p = market.position(users[i]);
                if (p.size == 0 || (p.size > 0) != (side == 0)) continue;
                uint256 worst =
                    Risk.worstClose(market.ammState(), p.size > 0, F.abs(p.size), market.config().sideCapBps);
                int256 loss = p.size > 0 ? int256(p.entryCost) - int256(worst) : int256(worst) - int256(p.entryCost);
                uint256 floor = (loss > 0 ? uint256(loss) : 0)
                    + Math.ceilDiv(p.entryCost * market.config().mmrBps, 10_000)
                    + Math.ceilDiv(worst * market.config().takerFeeBps, 10_000);
                int256 locked = vault.locked(users[i], address(market));
                uint256 capacity = locked > int256(floor) ? uint256(locked) - floor : 0;
                int256 index = p.lastFundingIndex + int256(capacity * 1e18 / F.abs(p.size));
                if (expected == address(0) || index < minIndex || (index == minIndex && users[i] < expected)) {
                    minIndex = index;
                    expected = users[i];
                }
            }
            (address actual, int256 actualMin) = market.fundingLimit(side == 0);
            assertEq(actual, expected);
            assertEq(actualMin, minIndex);
        }
    }

    function testFullBookMinimumClampsAndLiquidationRepairsHeap() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        address[] memory extras = new address[](126);
        for (uint256 i; i < extras.length; ++i) {
            extras[i] = address(uint160(0x9000 + i));
            _deposit(extras[i], 100e6);
            _open(extras[i], i % 2 == 0 ? int256(0.1e18) : -int256(0.1e18));
        }
        assertEq(market.positionCount(), 128);
        (address binding, int256 cap) = market.fundingLimit(true);
        vm.roll(block.number + 100_000_000);
        uint256 beforeGas = gasleft();
        market.poke();
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("128-position funding clamp gross gas", used);
        assertLt(used, 500_000);
        assertEq(market.fundingState().longIndex, cap);
        assertEq(market.fundingBinding(), binding);
        _checkHeaps();
        vm.prank(carol);
        market.liquidate(binding, "");
        assertEq(market.positionCount(), 127);
        assertEq(market.position(binding).size, 0);
        _checkHeaps();
        _assertCashWith(extras);
    }

    function testRepeatedOneWeiClosesCannotSpendResidualBackingThroughFeeRounding() public {
        Market low = Market(Clones.clone(address(new Market())));
        vault.registerMarket(address(low), creator);
        vm.prank(creator);
        vault.fundInsurance(address(low), 2_000e18);
        low.initialize(IMarginVault(address(vault)), 0, false, _config(false), 1e18, 2_000_000e18);
        vm.prank(alice);
        low.open(1000, type(uint256).max, "");
        vm.prank(bob);
        low.open(-10, 0, "");
        vm.roll(block.number + 1_000_000_000);
        assertEq(low.fundingBinding(), alice);
        uint256 insurance = vault.ledger(address(low)).insurance;
        vm.prank(bob);
        low.close(1e18, type(uint256).max, "");
        bool guarded;
        for (uint256 i; i < 1000; ++i) {
            T.Position memory p = low.position(alice);
            uint256 size = uint256(p.size);
            if (size <= 1) break;
            uint256 fraction = Math.ceilDiv(1e18, size);
            (, uint256 fee, int256 pnl, int256 owed) = low.quoteClose(alice, fraction);
            uint256 entry = p.entryCost - p.entryCost / size;
            uint256 worst = Risk.worstClose(low.ammState(), true, size - 1, low.config().sideCapBps);
            uint256 required = (entry > worst ? entry - worst : 0) + Math.ceilDiv(worst * 8, 10_000);
            int256 remaining = vault.locked(alice, address(low)) - owed + pnl - int256(fee);
            if (remaining < int256(required)) {
                vm.prank(alice);
                vm.expectPartialRevert(E.InsufficientMargin.selector);
                low.close(fraction, 0, "");
                assertEq(low.position(alice).size, p.size);
                guarded = true;
                break;
            }
            vm.prank(alice);
            low.close(fraction, 0, "");
        }
        assertTrue(guarded, "rounded per-chunk fees eventually exhaust removable collateral");
        vm.prank(alice);
        low.close(1e18, 0, "");
        assertEq(low.position(alice).size, 0);
        assertGe(vault.ledger(address(low)).insurance, insurance);
        assertEq(vault.protocolReserve(), 10_000e18);
    }
}
