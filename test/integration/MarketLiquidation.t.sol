// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InsuranceBackstop} from "../../src/InsuranceBackstop.sol";
import {IMarketCore} from "../../src/interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FundingMath} from "../../src/libraries/FundingMath.sol";
import {LiquidationMath as L} from "../../src/libraries/LiquidationMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MarketLiquidationTest is MarketFixture {
    InsuranceBackstop private backstop;

    function setUp() public {
        _setup(false);
        backstop = new InsuranceBackstop(address(vault));
        vault.setBackstopController(backstop);
        vm.prank(creator);
        vault.fundBackstop(10_000e18);
    }

    function testFundingDebtUsesInsuranceAndPreservesFundingIdentity() public {
        _indebted(3_000_000);
        uint256 insurance = vault.ledger(address(market)).insurance;
        uint256 keeper = vault.freeBalance(carol);
        (,, int256 pnl, int256 owed) = market.quoteClose(alice, 1e18);
        uint256 debt = uint256(owed - pnl - vault.locked(alice, address(market)));
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarketCore.BadDebt(address(market), alice, debt, 0);
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 0);
        assertEq(market.positionDebt(alice), 0);
        assertLt(vault.ledger(address(market)).insurance, insurance);
        assertEq(vault.backstopBalance(), 10_000e18);
        assertEq(vault.freeBalance(carol), keeper, "no reward funded by insurance");
        _finish();
    }

    function testBackstopAfterReceiverHasClosedAndWithdrawn() public {
        _indebted(7_000_000);
        _close(bob, 1e18);
        uint256 withdrawal = vault.freeBalance(bob) / 1e12;
        vm.prank(bob);
        vault.withdraw(withdrawal);
        uint256 bobFree = vault.freeBalance(bob);
        (,, int256 pnl, int256 owed) = market.quoteClose(alice, 1e18);
        uint256 debt = uint256(owed - pnl - vault.locked(alice, address(market)));
        uint256 insurance = vault.ledger(address(market)).insurance;
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarketCore.BadDebt(address(market), alice, insurance, 0);
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarketCore.BadDebt(address(market), alice, debt - insurance, 1);
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(vault.ledger(address(market)).insurance, 0);
        assertLt(vault.backstopBalance(), 10_000e18);
        assertGe(vault.backstopBalance(), 9_000e18);
        assertEq(vault.freeBalance(bob), bobFree);
        assertEq(market.positionDebt(alice), 0);
        _finish();
    }

    function testUncoveredLiquidationRollsBackAllEffects() public {
        _indebted(10_000_000);
        bytes32 beforeState = _stateHash();
        vm.prank(carol);
        vm.expectPartialRevert(E.UncoveredBadDebt.selector);
        market.liquidate(alice, "");
        assertEq(_stateHash(), beforeState);
        assertEq(backstop.capacity(address(market)), 1_000e18);
        (, bool initialized,, uint256 used) = backstop.windows(address(market));
        assertFalse(initialized);
        assertEq(used, 0);
        _assertCash();
    }

    function testVoluntaryFullCloseAlsoUsesCappedBackstop() public {
        _indebted(7_000_000);
        _close(alice, 1e18);
        assertLt(vault.backstopBalance(), 10_000e18);
        assertEq(market.positionDebt(alice), 0);
        _finish();
    }

    function testHealthyAndEmptyAccountsCannotBeLiquidated() public {
        vm.expectRevert(E.NoPosition.selector);
        market.liquidate(alice, "");
        _open(alice, 10e18);
        _open(bob, 9e18);
        vm.expectPartialRevert(E.NotLiquidatable.selector);
        market.liquidate(alice, "");
        _assertCash();
    }

    function testOraclelessLiquidationRejectsNativeValue() public {
        _indebted(3_000_000);
        vm.deal(carol, 1);
        vm.prank(carol);
        vm.expectRevert(E.UnexpectedValue.selector);
        market.liquidate{value: 1}(alice, "");
        assertEq(address(market).balance, 0);
    }

    function testFuzzFundingLiquidationConservesCash(uint32 elapsed, bool isLong) public {
        elapsed = uint32(bound(elapsed, 1_000_000, 7_000_000));
        _open(alice, isLong ? int256(10e18) : -int256(10e18));
        _open(bob, isLong ? -int256(1e18) : int256(1e18));
        vm.roll(block.number + elapsed);
        (, bool unhealthy) = market.health(alice);
        bytes32 beforeState = _stateHash();
        if (!unhealthy) vm.expectPartialRevert(E.NotLiquidatable.selector);
        vm.prank(carol);
        market.liquidate(alice, "");
        if (!unhealthy) {
            assertEq(_stateHash(), beforeState);
            _close(alice, 1e18);
        }
        assertEq(market.position(alice).size, 0);
        assertEq(market.positionDebt(alice), 0);
        _finish();
    }

    function _indebted(uint256 elapsed) private {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + elapsed);
        (, bool liquidatable) = market.health(alice);
        assertTrue(liquidatable);
    }

    function _finish() private {
        _assertCash();
        if (market.position(bob).size != 0) _close(bob, 1e18);
        market.sweepFundingSurplus();
        _assertCash();
        assertEq(vault.ledger(address(market)).clearing, 0);
        assertEq(vault.ledger(address(market)).fundingPool, 0);
        T.FundingState memory f = market.fundingState();
        assertEq(f.longWeighted, 0);
        assertEq(f.shortWeighted, 0);
        assertEq(FundingMath.pending(f, 0, 0), 0);
        assertEq(market.ammState().baseReserve, market.ammState().baseAtSeed);
    }

    function _stateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                market.ammState(),
                market.fundingState(),
                market.position(alice),
                vault.locked(alice, address(market)),
                vault.ledger(address(market)),
                vault.backstopBalance(),
                vault.freeBalance(carol)
            )
        );
    }
}

contract MarketOracleLiquidationTest is MarketFixture {
    function setUp() public {
        _setup(true);
    }

    function testFreshIndexTriggersCurveCloseAndExactPenaltySplit() public {
        _open(alice, 10e18);
        uint256 entry = market.position(alice).entryCost;
        uint256 margin = market.position(alice).margin;
        uint256 free = vault.freeBalance(alice);
        uint256 keeper = vault.freeBalance(carol);
        T.Ledger memory beforeLedger = vault.ledger(address(market));
        source.set(77e18, uint64(block.number), 0);
        uint256 penalty = L.penalty(entry, 150);
        vm.expectEmit(true, true, true, true, address(market));
        emit IMarketCore.Liquidated(address(market), alice, carol, 10e18, entry / 10, penalty, 0);
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 0);
        assertEq(vault.freeBalance(carol) - keeper, penalty * 40 / 100);
        assertEq(vault.freeBalance(alice), free + margin - penalty);
        T.Ledger memory afterLedger = vault.ledger(address(market));
        assertEq(afterLedger.insurance - beforeLedger.insurance, penalty - penalty * 40 / 100);
        assertEq(afterLedger.protocolOwed, beforeLedger.protocolOwed, "no additional taker fee");
        _assertCash();
    }

    function testAboveThresholdPartialRetainsHealthyCollateral() public {
        _open(alice, -10e18);
        _deposit(alice, 31_000e6);
        vm.prank(alice);
        market.addMargin(30_000e18);
        source.set(6_000e18, uint64(block.number), 0);
        uint256 free = vault.freeBalance(alice);
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, -5e18);
        assertEq(vault.freeBalance(alice), free, "partial retains collateral");
        (, bool unhealthy) = market.health(alice);
        assertFalse(unhealthy);
        _assertCash();
    }

    function testUnhealthyPartialCompletesAndGuardianPauseDoesNotBlock() public {
        _open(alice, -10e18);
        source.set(6_000e18, uint64(block.number), 0);
        vm.prank(guardian);
        market.pauseOpens();
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 0);
        assertTrue(market.guardianPaused());
        _assertCash();
    }

    function testUpdateFeeAndCallbackGuard() public {
        _open(alice, 10e18);
        source.set(77e18, uint64(block.number), 0);
        source.setFee(1);
        source.setCallback(address(market), abi.encodeCall(market.liquidate, (alice, bytes(""))));
        vm.deal(carol, 1);
        vm.prank(carol);
        market.liquidate{value: 1}(alice, "update");
        assertFalse(source.callbackSucceeded());
        assertEq(source.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(address(source).balance, 1);
        assertEq(address(market).balance, 0);
        _assertCash();
    }

    function testStaleSourceBeforeDegradationReverts() public {
        _open(alice, 10e18);
        vm.roll(block.number + 11);
        vm.expectPartialRevert(E.StaleOracle.selector);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 10e18);
        _assertCash();
    }
}

contract MarketDegradedLiquidationTest is MarketFixture {
    function setUp() public {
        _setup(true);
    }

    function _config(bool externalIndex) internal view override returns (T.MarketConfig memory c) {
        c = super._config(externalIndex);
        c.degradeAfterBlocks = 2_000_000;
    }

    function testDegradedPartialOnlyAndNoOracleRead() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 2_000_001);
        source.setBroken(true);
        uint256 calls = source.calls();
        vm.prank(carol);
        market.liquidate(alice, "ignored");
        assertEq(market.position(alice).size, 5e18);
        assertEq(source.calls(), calls);
        assertEq(market.fundingRatePerBlock(), 0);
        (, bool unhealthy) = market.health(alice);
        assertTrue(unhealthy, "degraded call must not escalate beyond half");
        _assertCash();
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 2.5e18);
        (, unhealthy) = market.health(alice);
        assertFalse(unhealthy);
        _assertCash();
    }

    function testLastBaseWeiCanExitDegradedMode() public {
        _open(alice, 1);
        _open(bob, -1);
        source.set(99e18, uint64(block.number), 0);
        market.remark();
        vm.roll(block.number + 2_000_001);
        vm.prank(carol);
        market.liquidate(alice, "");
        assertEq(market.position(alice).size, 0);
        assertEq(market.positionDebt(alice), 0);
        _assertCash();
    }
}
