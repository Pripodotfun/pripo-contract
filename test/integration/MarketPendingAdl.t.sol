// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../../src/interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {AdlFixture} from "../helpers/AdlFixture.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";
import {Vm} from "forge-std/Vm.sol";

contract MarketPendingAdlTest is AdlFixture {
    function setUp() public {
        _setup(false);
    }

    function testEmptyListLocksBudgetFreezesFundingAndCanContinueImmediately() public {
        _prepare(false);
        uint256 free = vault.freeBalance(alice);
        market.liquidate(alice, "", new address[](0));
        T.AdlPending memory p = market.pendingAdl(alice);
        T.FundingState memory f = market.fundingState();
        assertTrue(p.active);
        assertEq(p.matchedSize, 0);
        assertEq(p.S0, 10e18);
        assertEq(p.budget, p.M0 + int256(p.reservedC - p.allowanceFromC));
        assertEq(vault.adlReserved(address(market), alice), p.reservedC + p.allowanceFromReserve);
        assertEq(vault.ledger(address(market)).insurance, 0);
        assertEq(vault.freeBalance(alice), free);
        assertEq(market.fundingRatePerBlock(), 0);
        vm.prank(alice);
        vm.expectRevert(E.AdlAlreadyPending.selector);
        market.close(1e18, 0, "");
        vm.prank(alice);
        vm.expectRevert(E.AdlAlreadyPending.selector);
        market.removeMargin(1);
        vm.expectRevert(E.AdlAlreadyPending.selector);
        market.liquidate(alice, "");
        vm.prank(carol);
        vm.expectRevert(E.MarketNotActive.selector);
        market.open(1e18, type(uint256).max, "");
        vm.roll(block.number + 500);
        market.poke();
        market.remark();
        market.resumeOpens();
        assertEq(market.fundingState().longIndex, f.longIndex);
        assertEq(market.fundingState().shortIndex, f.shortIndex);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Paused));
        _assertCash();
        address[] memory candidates = new address[](1);
        candidates[0] = bob;
        vm.prank(carol);
        market.continueAdl(alice, candidates);
        assertEq(market.position(alice).size, 0);
        assertFalse(market.pendingAdl(alice).active);
        assertEq(market.pendingAdlCount(), 0);
        assertEq(vault.adlReservedTotal(address(market)), 0);
        assertEq(market.fundingState().longIndex, f.longIndex);
        assertEq(market.fundingState().shortIndex, f.shortIndex);
        assertEq(market.fundingState().lastBlock, block.number);
        _assertCash();
    }

    function testPartialContinuationRetainsLoserFundsAndMarginAdditionReplacesUnspentCoverage() public {
        _prepareSplit(false, 8e18);
        uint256 free = vault.freeBalance(alice);
        address[] memory list = new address[](1);
        list[0] = bob;
        market.liquidate(alice, "", list);
        T.AdlPending memory before = market.pendingAdl(alice);
        assertEq(before.matchedSize, 8e18);
        assertEq(vault.freeBalance(alice), free);
        assertEq(market.position(alice).entryCost, before.E0 - before.E0 * 8 / 10);
        uint256 reserved = vault.adlReserved(address(market), alice);
        int256 locked = vault.locked(alice, address(market));
        vm.prank(alice);
        market.addMargin(5e18);
        T.AdlPending memory afterAdd = market.pendingAdl(alice);
        assertEq(afterAdd.S0, before.S0);
        assertEq(afterAdd.E0, before.E0);
        assertEq(afterAdd.V0, before.V0);
        assertEq(afterAdd.budget, before.budget);
        assertEq(afterAdd.since, before.since);
        assertEq(afterAdd.matchedSize, before.matchedSize);
        assertEq(afterAdd.allowanceConsumed, before.allowanceConsumed);
        assertEq(afterAdd.replacedC, 5e18);
        assertEq(vault.adlReserved(address(market), alice), reserved - 5e18);
        assertEq(vault.locked(alice, address(market)), locked + 5e18);
        assertEq(vault.freeBalance(alice), free - 5e18);
        _assertCash();
        vm.roll(block.number + 400);
        list[0] = creator;
        market.continueAdl(alice, list);
        assertEq(market.position(alice).size, 0);
        assertEq(vault.locked(alice, address(market)), 0);
        assertEq(vault.adlReservedTotal(address(market)), 0);
        _assertCash();
    }

    function testFallbackDeadlineOnlyEnablesScanAndEverySingleSlotCallProgresses() public {
        _prepare(false);
        market.liquidate(alice, "", new address[](0));
        uint256 ready = uint256(market.pendingAdl(alice).since) + market.config().adlPendingWindow;
        vm.expectRevert(abi.encodeWithSelector(E.AdlFallbackNotReady.selector, ready));
        market.completeAdl(alice, 1);
        vm.roll(ready);
        assertTrue(market.pendingAdl(alice).active);
        assertEq(market.adlEligibleSize(alice), 20e18);
        vm.expectRevert(E.InvalidAdlIterations.selector);
        market.completeAdl(alice, 0);
        vm.expectRevert(E.InvalidAdlIterations.selector);
        market.completeAdl(alice, 65);
        vm.prank(bob);
        market.completeAdl(alice, 1);
        assertEq(market.pendingAdl(alice).cursor, 1);
        assertEq(market.pendingAdl(alice).matchedSize, 0);
        market.completeAdl(alice, 1);
        assertEq(market.pendingAdl(alice).cursor, 2);
        market.completeAdl(alice, 1);
        assertFalse(market.pendingAdl(alice).active);
        assertEq(market.position(alice).size, 0);
        _assertCash();
    }

    function testFallbackDoesNotSkipWinnerAfterEarlierWinnerCloses() public {
        _prepareSplit(false, 8e18);
        market.liquidate(alice, "", new address[](0));
        vm.roll(block.number + market.config().adlPendingWindow);
        market.completeAdl(alice, 1);
        uint256 creatorSlot = market.position(creator).slot;
        _close(bob, 1e18);
        assertEq(market.position(creator).slot, creatorSlot);
        assertEq(market.positionAccounts(2, 1)[0], address(0));
        market.completeAdl(alice, 2);
        assertEq(market.pendingAdl(alice).cursor, 3);
        assertEq(market.pendingAdl(alice).matchedSize, 0);
        market.completeAdl(alice, 1);
        assertEq(market.position(alice).size, 0);
        assertFalse(market.pendingAdl(alice).active);
        _assertCash();
    }

    function testFreshInsufficiencyAfterWinnerClosesSettlesAndClearsAllReservations() public {
        _prepareSplit(false, 8e18);
        market.liquidate(alice, "", new address[](0));
        vm.roll(block.number + market.config().adlPendingWindow);
        market.completeAdl(alice, 1);
        _close(bob, 1e18);
        _close(creator, 0.5e18);
        uint256 eligible = market.adlEligibleSize(alice);
        assertLt(eligible, 10e18);
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarketCore.AdlInsufficient(address(market), alice, eligible, 10e18);
        market.completeAdl(alice, 1);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Settled));
        assertEq(market.positionCount(), 0);
        assertEq(market.pendingAdlCount(), 0);
        assertEq(vault.adlReservedTotal(address(market)), 0);
        assertEq(vault.adlReservationCount(address(market)), 0);
        assertFalse(market.pendingAdl(alice).active);
        _assertCash();
    }

    function testTwoPendingsKeepFundingFrozenAndGuardianPauseSurvivesCompletion() public {
        _open(alice, 5e18);
        _open(creator, 5e18);
        _open(carol, 10e18);
        _open(bob, -20e18);
        _open(carol, 1e18);
        vm.roll(block.number + 50_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        _setPostFundingMargin(alice, -int256(vault.ledger(address(market)).insurance) + 0.1e18);
        _setPostFundingMargin(creator, -0.01e18);
        market.liquidate(alice, "", new address[](0));
        market.liquidate(creator, "", new address[](0));
        assertEq(market.pendingAdlCount(), 2);
        assertEq(market.pendingAdl(creator).allowanceFromReserve, 128);
        assertEq(vault.protocolReserve(), vault.reserveFloor() - 128);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        vault.requireOpenAllowed(address(market));
        T.FundingState memory f = market.fundingState();
        vm.prank(guardian);
        market.pauseOpens();
        address[] memory list = new address[](1);
        list[0] = bob;
        market.continueAdl(alice, list);
        assertEq(market.pendingAdlCount(), 1);
        assertEq(market.fundingRatePerBlock(), 0);
        vm.roll(block.number + 5_000);
        market.poke();
        assertEq(market.fundingState().longIndex, f.longIndex);
        assertEq(market.fundingState().shortIndex, f.shortIndex);
        market.continueAdl(creator, list);
        assertEq(market.pendingAdlCount(), 0);
        assertTrue(market.guardianPaused());
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Paused));
        assertEq(vault.protocolReserve(), vault.reserveFloor());
        assertEq(vault.adlReservedTotal(address(market)), 0);
        market.resumeOpens();
        (status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
        _assertCash();
    }

    function testExhaustedAllowanceEmitsZeroProfitWithoutSpendingAnotherPendingReservation() public {
        address dave = address(0xda7e);
        _deposit(dave, 10_000e6);
        _open(alice, 5e18);
        _open(creator, 5e18);
        _open(carol, 10e18);
        _open(bob, -(5e18 - 1));
        _open(dave, -(15e18 + 1));
        _open(carol, 1e18);
        vm.roll(block.number + 50_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        _setPostFundingMargin(alice, -int256(vault.ledger(address(market)).insurance) + 0.1e18);
        _setPostFundingMargin(creator, 0);
        market.liquidate(alice, "", new address[](0));
        uint256 aliceReservation = vault.adlReserved(address(market), alice);

        // Another market's terminal obligation consumes the unreserved global capital. Main-market state is untouched.
        TerminalMarketStub dead = new TerminalMarketStub();
        vault.registerMarket(address(dead), carol);
        uint256 capital = vault.protocolReserve();
        vm.startPrank(address(dead));
        vault.settleFunding(alice, int256(capital));
        vault.settleFunding(carol, -int256(capital));
        vault.release(carol, capital);
        vm.stopPrank();
        dead.setState(T.Status.Settled, 0, 0);
        address[] memory debtors = new address[](1);
        debtors[0] = alice;
        vm.prank(address(dead));
        vault.finalizeSettlement(debtors);
        assertEq(vault.protocolReserve(), 0);
        assertEq(vault.adlReserved(address(market), alice), aliceReservation);

        address[] memory list = new address[](1);
        list[0] = bob;
        market.liquidate(creator, "", list);
        T.AdlPending memory p = market.pendingAdl(creator);
        assertTrue(p.active);
        assertEq(p.S0 - p.matchedSize, 1);
        assertEq(p.allowanceFromC + p.allowanceFromReserve, 0);
        list[0] = dave;
        vm.expectEmit(true, true, false, true, address(market));
        emit IMarketCore.AdlZeroProfit(address(market), dave, -1);
        market.continueAdl(creator, list);
        assertFalse(market.pendingAdl(creator).active);
        assertEq(vault.adlReserved(address(market), alice), aliceReservation);
        assertEq(market.pendingAdlCount(), 1);
        market.continueAdl(alice, list);
        assertEq(market.pendingAdlCount(), 0);
        address[] memory extras = new address[](1);
        extras[0] = dave;
        _assertCashWith(extras);
    }

    function _setPostFundingMargin(address user, int256 desired) internal {
        (,,, int256 owed) = market.quoteClose(user, 1e18);
        int256 current = vault.locked(user, address(market)) - owed;
        assertLt(current, desired);
        vm.prank(user);
        market.addMargin(uint256(desired - current));
    }

    function testFuzzRuntimeScheduleAndReliefAcrossExplicitContinuations(uint96 firstSizeSeed, bool short) public {
        // Keep each full candidate above close-alone quote dust; the final chunk may still be one wei.
        uint256 firstSize = bound(firstSizeSeed, 1e6, 10e18 - 1);
        _prepareSplit(short, firstSize);
        market.liquidate(alice, "", new address[](0));
        T.AdlPending memory initial = market.pendingAdl(alice);
        uint256 value;
        uint256 chunks;
        uint256 topUps;
        address[] memory list = new address[](1);
        for (uint256 i; i < 2; ++i) {
            list[0] = i == 0 ? bob : creator;
            vm.recordLogs();
            market.continueAdl(alice, list);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 topUp;
            for (uint256 j; j < logs.length; ++j) {
                if (
                    logs[j].emitter == address(vault)
                        && logs[j].topics[0] == keccak256("AdlRoundingPaid(address,address,address)")
                ) {
                    assertEq(address(uint160(uint256(logs[j].topics[2]))), alice);
                    assertEq(address(uint160(uint256(logs[j].topics[3]))), list[0]);
                    ++topUp;
                    ++topUps;
                }
                if (
                    logs[j].emitter == address(market)
                        && logs[j].topics[0]
                            == keccak256("AutoDeleveraged(address,address,address,int256,uint256,uint256)")
                ) {
                    (int256 size, uint256 quote, uint256 entry) = abi.decode(logs[j].data, (int256, uint256, uint256));
                    int256 booked = size > 0 ? int256(quote) - int256(entry) : int256(entry) - int256(quote);
                    assertGe(booked, 0);
                    assertLe(topUp, 1);
                    assertEq(topUp, booked == 0 ? 1 : 0);
                    assertGe(booked + int256(topUp), 1);
                    value += quote;
                    ++chunks;
                }
            }
            if (i == 0) {
                T.AdlPending memory pending = market.pendingAdl(alice);
                uint256 scheduled = uint256(initial.V0) * pending.matchedSize / initial.S0;
                assertEq(value, short ? scheduled - pending.relief : scheduled + pending.relief);
                assertEq(pending.E0, initial.E0);
                assertEq(pending.S0, initial.S0);
                assertEq(pending.V0, initial.V0);
                assertEq(pending.allowanceConsumed, topUps);
                assertLe(pending.allowanceConsumed, pending.chunksMatched);
                vm.roll(block.number + 1);
            } else {
                uint256 relief;
                for (uint256 j; j < logs.length; ++j) {
                    if (
                        logs[j].emitter == address(market)
                            && logs[j].topics[0] == keccak256("AdlCompleted(address,address,uint256,uint256)")
                    ) {
                        (relief,) = abi.decode(logs[j].data, (uint256, uint256));
                    }
                }
                assertEq(value, short ? uint256(initial.V0) - relief : uint256(initial.V0) + relief);
                int256 loss = short ? int256(value) - int256(initial.E0) : int256(initial.E0) - int256(value);
                assertEq(loss, initial.budget - int256(relief));
                assertFalse(market.pendingAdl(alice).active);
            }
            _assertCash();
        }
        assertEq(chunks, 2);
        assertLe(topUps, chunks);
        assertLe(topUps, initial.allowanceFromC + initial.allowanceFromReserve);
    }
}
