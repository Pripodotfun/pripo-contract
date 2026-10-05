// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {MarkTwap} from "../../src/libraries/MarkTwap.sol";
import {MarketState as S} from "../../src/market/MarketState.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract RiskViewHarness is Market {
    using MarkTwap for MarkTwap.State;

    function setTestState(T.Status status_, bool pending, address binding, uint256 twap) external {
        S.Data storage s = S.load();
        s._config.status = status_;
        s._pendingAdl[msg.sender].active = pending;
        s._positions[msg.sender].adlPending = pending;
        s.pendingAdlCount = pending ? 1 : 0;
        s.fundingBinding = binding;
        if (twap != 0) {
            delete s._twap;
            s._twap.initialize(twap, uint64(block.number));
        }
    }
}

contract MarketRiskBookViewTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function _config(bool externalIndex) internal view override returns (T.MarketConfig memory c) {
        c = super._config(externalIndex);
        c.maxPositionsPerMarket = 2;
    }

    function testFullBookAllowsIncreasesAndFreedSlotRestoresCapacity() public {
        _open(alice, 1e18);
        _open(bob, -1e18);
        assertEq(market.maxOpenable(carol, true), 0);
        int256 additional = market.maxOpenable(alice, true);
        assertGt(additional, 0);
        _open(alice, additional);
        assertEq(market.positionCount(), 2);
        _close(bob, 1e18);
        assertGt(market.maxOpenable(carol, true), 0);
    }
}

contract MarketRiskViewsTest is MarketFixture {
    function setUp() public {
        vm.roll(1000);
        _setup(true);
    }

    function _marketImplementation() internal override returns (address) {
        return address(new RiskViewHarness());
    }

    function testFuzzMaximumExecutesAndNextWeiCannot(uint96 funds, uint64 initial, bool long) public {
        if (initial % 2 != 0) _open(alice, long ? int256(1e18) : -int256(1e18));
        _open(bob, long ? -int256(5e18) : int256(5e18));
        vm.roll(block.number + initial % 80);
        source.set(100e18, uint64(block.number), 0);
        uint256 freeRaw = vault.freeBalance(alice) / 1e12;
        uint256 retained = uint256(funds) % (freeRaw + 1);
        uint256 withdrawal = freeRaw - retained;
        if (withdrawal != 0) {
            vm.startPrank(alice);
            vault.withdraw(withdrawal);
            vm.stopPrank();
        }
        _assertMaximum(alice, long);
    }

    function testIndexPricesMatchActualHealthAndLiquidationAtAdjacentWei() public {
        _open(alice, 10e18);
        _open(bob, -5e18);
        _assertIndexBoundary(alice, true);
        _assertIndexBoundary(bob, false);
    }

    function testGatesOppositeSideAndTaggedNonPriceReasons() public {
        assertEq(market.maxOpenable(address(0), true), 0);
        (,, T.LiquidationPriceReason reason) = market.liquidationPriceInfo(alice);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.NoPosition));
        _open(alice, 1e18);
        assertEq(market.maxOpenable(alice, false), 0);
        vm.prank(guardian);
        market.pauseOpens();
        assertEq(market.maxOpenable(bob, false), 0);
        market.resumeOpens();
        vm.prank(alice);
        RiskViewHarness(address(market)).setTestState(T.Status.Paused, true, address(0), 0);
        assertEq(market.maxOpenable(bob, false), 0);
        (,, reason) = market.liquidationPriceInfo(alice);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.PendingAdl));
        vm.prank(alice);
        RiskViewHarness(address(market)).setTestState(T.Status.Active, false, alice, 0);
        assertEq(market.liquidationPrice(alice), 0);
        (,, reason) = market.liquidationPriceInfo(alice);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.FundingCapacity));
        vm.prank(alice);
        RiskViewHarness(address(market)).setTestState(T.Status.Settled, false, address(0), 0);
        assertEq(market.maxOpenable(bob, false), 0);
        (,, reason) = market.liquidationPriceInfo(alice);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.Inactive));
    }

    function testDegradedTwapThresholdUsesExactCloseAndHigherMaintenance() public {
        _open(alice, 10e18);
        vm.prank(alice);
        RiskViewHarness(address(market)).setTestState(T.Status.Degraded, false, address(0), 100e18);
        (uint256 price, T.LiquidationReference kind, T.LiquidationPriceReason reason) =
            market.liquidationPriceInfo(alice);
        assertEq(uint8(kind), uint8(T.LiquidationReference.Twap));
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.Threshold));
        assertGt(price, 0);
        vm.prank(alice);
        RiskViewHarness(address(market)).setTestState(T.Status.Degraded, false, address(0), price + 1);
        (, bool unhealthy) = market.health(alice);
        assertFalse(unhealthy);
        vm.prank(alice);
        RiskViewHarness(address(market)).setTestState(T.Status.Degraded, false, address(0), price);
        (, unhealthy) = market.health(alice);
        assertTrue(unhealthy);
        assertEq(market.liquidationPrice(alice), 0);
        (,, reason) = market.liquidationPriceInfo(alice);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.TwapAlreadyLiquidatable));
    }

    function testShortOpenCanRestoreAnExceededLongQuoteCap() public {
        for (uint256 i; i < 13; ++i) {
            address user = address(uint160(0x1000 + i));
            _deposit(user, 1_000e6);
            int256 amount = market.maxOpenable(user, true);
            if (i == 6) _open(bob, -10e18);
            if (amount != 0) _open(user, amount);
        }
        _close(bob, 1e18);
        (uint256 longs,, uint256 cap) = market.openInterest();
        assertGt(longs, cap);
        vm.expectPartialRevert(E.OICapExceeded.selector);
        market.quoteOpenFor(bob, -1);
        _assertMaximum(bob, false);
    }

    function testFundingBindingPreviewIsReportedBeforePoke() public {
        market = _newMarket(false);
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 3_000_000);
        address binding = market.fundingBinding();
        assertEq(binding, alice);
        (,, T.LiquidationPriceReason reason) = market.liquidationPriceInfo(binding);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.FundingCapacity));
        _assertMaximum(alice, true);
    }

    function testNoCrossingNegativeCollateralAndVaultGate() public {
        _open(alice, 1e18);
        vm.prank(alice);
        market.addMargin(1000e18);
        (uint256 price,, T.LiquidationPriceReason reason) = market.liquidationPriceInfo(alice);
        assertEq(price, 0);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.NoCrossing));
        int256 locked = vault.locked(alice, address(market));
        vm.prank(address(market));
        vault.settleFunding(alice, locked + 1);
        (price,, reason) = market.liquidationPriceInfo(alice);
        assertEq(price, 0);
        assertEq(uint8(reason), uint8(T.LiquidationPriceReason.NegativeCollateral));
        vm.mockCallRevert(
            address(vault),
            abi.encodeCall(vault.requireOpenAllowed, (address(market))),
            abi.encodeWithSelector(E.ReserveBelowFloor.selector, 0, 10_000e18)
        );
        assertEq(market.maxOpenable(bob, false), 0);
        vm.clearMockedCalls();
    }

    function testMaximumAtLaunchPriceExtremesHasBoundedGas() public {
        uint256[2] memory prices = [uint256(2e14), uint256(1e28)];
        for (uint256 i; i < prices.length; ++i) {
            source.set(prices[i], uint64(block.number), 0);
            market = _newMarket(true);
            for (uint256 side; side < 2; ++side) {
                uint256 start = gasleft();
                int256 amount = market.maxOpenable(alice, side == 0);
                uint256 used = start - gasleft();
                emit log_named_uint("maximum view at price extreme gross gas", used);
                assertLt(used, 5_000_000);
                assertTrue(amount != 0);
                _assertMaximum(alice, side == 0);
            }
        }
    }

    function _assertMaximum(address user, bool long) internal {
        int256 amount = market.maxOpenable(user, long);
        uint256 checkpoint = vm.snapshotState();
        if (amount != 0) {
            (, uint256 fee, uint256 margin,) = market.quoteOpenFor(user, amount);
            uint256 before = vault.freeBalance(user);
            int256 previousSize = market.position(user).size;
            _open(user, amount);
            assertEq(market.position(user).size, previousSize + amount);
            assertEq(before - vault.freeBalance(user), margin + fee);
            assertTrue(vm.revertToState(checkpoint));
        }
        vm.prank(user);
        vm.expectRevert();
        market.open(amount + (long ? int256(1) : -int256(1)), long ? type(uint256).max : 0, "");
    }

    function _assertIndexBoundary(address user, bool long) internal {
        uint256 checkpoint = vm.snapshotState();
        uint256 price = market.liquidationPrice(user);
        assertGt(price, 0);
        source.set(long ? price + 1 : price - 1, uint64(block.number), 0);
        market.remark();
        (, bool unhealthy) = market.health(user);
        assertFalse(unhealthy);
        vm.expectPartialRevert(E.NotLiquidatable.selector);
        market.liquidate(user, "");
        source.set(price, uint64(block.number), 0);
        market.remark();
        (, unhealthy) = market.health(user);
        assertTrue(unhealthy);
        market.liquidate(user, "");
        assertEq(market.position(user).size, 0);
        assertTrue(vm.revertToState(checkpoint));
    }
}
