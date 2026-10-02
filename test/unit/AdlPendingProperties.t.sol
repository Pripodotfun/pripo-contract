// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {PositionBook as Book} from "../../src/market/PositionBook.sol";
import {AdlFallbackHarness, AdlScheduleHarness} from "../helpers/AdlPendingHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract AdlPendingPropertiesTest is Test {
    struct Oracle {
        uint256 size;
        uint256 entry;
        uint256 scheduled;
        uint256 actual;
        uint256 relief;
        uint256 entryRemainder;
        uint256 valueRemainder;
    }

    function testFuzzActualValuesIncludeReliefAcrossContinuations(
        uint96 sizeSeed,
        uint80 entrySeed,
        uint80 budgetSeed,
        uint8 countSeed,
        uint256 entropy,
        bool longTarget
    ) public {
        uint256 count = bound(countSeed, 1, Book.MAX_POSITIONS - 1);
        uint256 size = bound(sizeSeed, count, 1e24);
        uint256 entry = bound(entrySeed, 1, 1e24);
        uint256 budget = bound(budgetSeed, 0, longTarget ? entry : 1e24);
        uint256 value = longTarget ? entry - budget : entry + budget;
        AdlScheduleHarness.Snapshot memory s = AdlScheduleHarness.Snapshot(size, entry, value, longTarget);
        AdlScheduleHarness h = new AdlScheduleHarness(s, Book.MAX_POSITIONS, Book.MAX_POSITIONS, 0);
        Oracle memory o;
        uint256 completed;
        uint256 nextBlock = block.number;
        while (completed < count) {
            entropy = _next(entropy);
            uint256 batch = 1 + entropy % Math.min(64, count - completed);
            AdlScheduleHarness.Chunk[] memory chunks = new AdlScheduleHarness.Chunk[](batch);
            for (uint256 i; i < batch; ++i) {
                entropy = _next(entropy);
                uint256 left = count - completed - i;
                uint256 amount = left == 1 ? size - o.size : 1 + entropy % (size - o.size - left + 1);
                entropy = _next(entropy);
                uint256 realizable = entropy % (2e24 + 1);
                chunks[i] = AdlScheduleHarness.Chunk(amount, realizable, 1);
                // Independent oracle carries division remainders instead of subtracting cumulative prefixes.
                uint256 entryNumerator = entry * amount + o.entryRemainder;
                uint256 valueNumerator = value * amount + o.valueRemainder;
                o.entry += entryNumerator / size;
                o.entryRemainder = entryNumerator % size;
                uint256 scheduled = valueNumerator / size;
                o.valueRemainder = valueNumerator % size;
                uint256 actual = longTarget ? Math.max(scheduled, realizable) : Math.min(scheduled, realizable);
                o.scheduled += scheduled;
                o.actual += actual;
                o.relief += longTarget ? actual - scheduled : scheduled - actual;
                o.size += amount;
            }
            nextBlock += 1 + entropy % 1000;
            vm.roll(nextBlock);
            h.continueAdl(chunks);
            completed += batch;
            _assertSchedule(h, s, o);
            assertEq(h.chunksMatched(), completed);
        }
        assertEq(o.size, size);
        assertEq(o.entry, entry);
        assertEq(o.scheduled, value);
        assertEq(o.entryRemainder, 0);
        assertEq(o.valueRemainder, 0);
        assertEq(o.actual, longTarget ? value + o.relief : value - o.relief);
        int256 loss = longTarget ? F.toInt(o.entry) - F.toInt(o.actual) : F.toInt(o.actual) - F.toInt(o.entry);
        assertEq(loss, F.toInt(budget) - F.toInt(o.relief));
    }

    function testFuzzAllowanceConsumptionIsBoundedByMatchedChunks(
        uint8 capSeed,
        uint8 countSeed,
        uint16 coverageSeed,
        uint16 reserveSeed,
        uint256 entropy,
        bool longTarget
    ) public {
        uint256 cap = bound(capSeed, 2, Book.MAX_POSITIONS);
        uint256 count = bound(countSeed, 1, cap - 1);
        uint256 coverage = bound(coverageSeed, 0, cap * 2);
        uint256 reserve = bound(reserveSeed, 0, cap * 2);
        // These ratios give every full one-unit winner exact positive PnL, with count-1 rounded zeros.
        uint256 value = longTarget ? 2 * count - 1 : count + 1;
        AdlScheduleHarness.Snapshot memory s =
            AdlScheduleHarness.Snapshot(count, longTarget ? 3 * count : count, value, longTarget);
        AdlScheduleHarness h = new AdlScheduleHarness(s, cap, coverage, reserve);
        uint256 funded = Math.min(cap, coverage + reserve);
        assertEq(h.allowanceFromCoverage(), Math.min(cap, coverage));
        assertEq(h.allowanceFromReserve(), funded - Math.min(cap, coverage));
        assertEq(h.lossCoverage() + h.allowanceFromCoverage(), coverage);
        assertEq(h.reserveRemaining() + h.allowanceFromReserve(), reserve);
        uint256 completed;
        uint256 expectedConsumed;
        uint256 valueRemainder;
        uint256 zeroEvents;
        bool[] memory shouldEmitZero = new bool[](count);
        if (longTarget) assertGt(2 * count, value, "short winners have exact positive schedule profit");
        else assertLt(count, value, "long winners have exact positive schedule profit");
        vm.recordLogs();
        while (completed < count) {
            entropy = _next(entropy);
            uint256 batch = 1 + entropy % Math.min(64, count - completed);
            AdlScheduleHarness.Chunk[] memory chunks = new AdlScheduleHarness.Chunk[](batch);
            uint256[] memory expectedPaid = new uint256[](batch);
            for (uint256 i; i < batch; ++i) {
                uint256 numerator = value + valueRemainder;
                uint256 scheduled = numerator / count;
                valueRemainder = numerator % count;
                uint256 profit = longTarget ? 2 - scheduled : scheduled - 1;
                chunks[i] = AdlScheduleHarness.Chunk(1, longTarget ? 1 : 2, profit);
                expectedPaid[i] = profit;
                if (profit == 0 && expectedConsumed < funded) {
                    ++expectedConsumed;
                    expectedPaid[i] = 1;
                } else if (profit == 0) {
                    shouldEmitZero[completed + i] = true;
                    ++zeroEvents;
                }
            }
            uint256[] memory paid = h.continueAdl(chunks);
            assertEq(paid, expectedPaid);
            completed += batch;
            assertEq(h.allowanceConsumed(), expectedConsumed);
            assertLe(h.allowanceConsumed(), h.chunksMatched());
            assertEq(h.allowance() + h.allowanceConsumed(), funded);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, zeroEvents);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(h));
            assertEq(logs[i].topics[0], keccak256("AdlZeroProfit(uint256)"));
            uint256 chunk = uint256(logs[i].topics[1]);
            assertTrue(shouldEmitZero[chunk]);
            shouldEmitZero[chunk] = false;
        }
        for (uint256 i; i < count; ++i) {
            assertFalse(shouldEmitZero[i], "every unpaid zero has its event, exactly once");
        }
        assertEq(expectedConsumed, Math.min(funded, count - 1));
        assertEq(zeroEvents, count - 1 - expectedConsumed);
        if (funded == cap) assertEq(zeroEvents, 0);
    }

    function testFuzzFallbackTerminatesFromAnyCursorWithWinnerCloses(
        uint8 capSeed,
        uint8 cursorSeed,
        uint96 sizeSeed,
        uint256 entropy
    ) public {
        uint256 cap = bound(capSeed, 2, Book.MAX_POSITIONS);
        AdlFallbackHarness.Slot[] memory initial = new AdlFallbackHarness.Slot[](cap);
        // Slot zero represents the pending loser and is excluded from opposite-side matching.
        for (uint256 i = 1; i < cap; ++i) {
            entropy = _next(entropy);
            initial[i] = AdlFallbackHarness.Slot(entropy % 1000, (entropy >> 16) % 3 != 0);
        }
        uint256 required = bound(sizeSeed, 1, _eligible(initial) + 1);
        AdlFallbackHarness h = new AdlFallbackHarness(initial, required, bound(cursorSeed, 0, cap));
        uint256 calls;
        uint256 mutations;
        uint256 inspectedAtMutation;
        while (h.remaining() != 0 && !h.settled()) {
            assertLt(calls, cap * (cap + 1) + 1, "finite winner closes cannot prevent eventual completion or proof");
            AdlFallbackHarness.Slot[] memory beforeBook = h.book();
            entropy = _next(entropy);
            uint256 victim = 1 + entropy % (cap - 1);
            if (
                mutations < cap && (entropy >> 16) % 2 == 0 && beforeBook[victim].eligible
                    && beforeBook[victim].size != 0
            ) {
                uint256 amount = (entropy >> 24) % 2 == 0
                    ? beforeBook[victim].size
                    : 1 + (entropy >> 32) % beforeBook[victim].size;
                h.closeWinnerSize(victim, amount);
                AdlFallbackHarness.Slot[] memory closedBook = h.book();
                for (uint256 i; i < cap; ++i) {
                    if (i == victim) {
                        assertEq(closedBook[i].size, beforeBook[i].size - amount);
                    } else {
                        assertEq(
                            abi.encode(closedBook[i]), abi.encode(beforeBook[i]), "close must not move another slot"
                        );
                    }
                }
                ++mutations;
                inspectedAtMutation = h.inspected();
                // Closes can change realizable prices. Refresh current eligibility, including slots behind the cursor.
                h.refreshEligibility(_next(entropy));
                beforeBook = h.book();
                for (uint256 i; i < cap; ++i) {
                    assertEq(beforeBook[i].size, closedBook[i].size, "repricing never moves or resizes a slot");
                }
            }
            uint256 eligibleBefore = _eligible(beforeBook);
            uint256 remainingBefore = h.remaining();
            uint256 inspectedBefore = h.inspected();
            uint256 matchedBefore = h.matched();
            uint256 cursorBefore = h.cursor() % cap;
            entropy = _next(entropy);
            uint256 iterations = 1 + entropy % 64;
            h.completeAdl(iterations);
            ++calls;
            uint256 scanned = h.inspected() - inspectedBefore;
            assertLe(scanned, iterations);
            assertTrue(h.settled() || h.matched() > matchedBefore || scanned > 0);
            assertEq(h.settled(), eligibleBefore < remainingBefore, "terminal proof uses this call's live book");
            if (h.settled()) {
                assertEq(h.eligibleAtSettlement(), eligibleBefore);
                assertEq(h.remaining(), remainingBefore);
            }
            AdlFallbackHarness.Slot[] memory afterBook = h.book();
            uint256 reduction;
            for (uint256 i; i < cap; ++i) {
                uint256 distance = (i + cap - cursorBefore) % cap;
                assertLe(afterBook[i].size, beforeBook[i].size);
                if (distance >= scanned || !beforeBook[i].eligible) {
                    assertEq(
                        abi.encode(afterBook[i]), abi.encode(beforeBook[i]), "unvisited or ineligible slot is unchanged"
                    );
                }
                reduction += beforeBook[i].size - afterBook[i].size;
            }
            assertEq(reduction, remainingBefore - h.remaining());
            assertEq(h.matched() + h.remaining(), required);
            assertLe(h.inspected() - inspectedAtMutation, cap, "one cyclic pass suffices without further mutations");
            assertLe(h.inspected(), cap * (mutations + 1));
            assertLe(mutations, cap, "the fuzz trace has a finite budget of external mutations");
        }
        assertTrue(h.remaining() == 0 || h.settled());
        AdlFallbackHarness.Slot[] memory finalBook = h.book();
        uint256 initialSize;
        uint256 finalSize;
        for (uint256 i; i < cap; ++i) {
            initialSize += initial[i].size;
            finalSize += finalBook[i].size;
        }
        assertEq(finalSize + h.matched() + h.closedOutside(), initialSize);
    }

    function testFallbackWrapsFromEndAndSkipsClosedSlotsWithoutMovingSurvivors() public {
        AdlFallbackHarness.Slot[] memory slots = new AdlFallbackHarness.Slot[](Book.MAX_POSITIONS);
        slots[1] = AdlFallbackHarness.Slot(3, true);
        slots[100] = AdlFallbackHarness.Slot(4, true);
        AdlFallbackHarness h = new AdlFallbackHarness(slots, 3, Book.MAX_POSITIONS);
        h.closeWinner(100);
        h.completeAdl(1);
        assertEq(h.cursor(), 1);
        assertEq(h.remaining(), 3);
        h.completeAdl(1);
        assertEq(h.remaining(), 0);
        assertFalse(h.settled());
    }

    function testFallbackRechecksInsufficiencyAfterWinnerClosesBetweenCalls() public {
        AdlFallbackHarness.Slot[] memory slots = new AdlFallbackHarness.Slot[](4);
        slots[2] = AdlFallbackHarness.Slot(5, true);
        slots[3] = AdlFallbackHarness.Slot(5, true);
        AdlFallbackHarness h = new AdlFallbackHarness(slots, 8, 0);
        h.completeAdl(1);
        assertFalse(h.settled());
        h.closeWinner(3);
        h.completeAdl(1);
        assertTrue(h.settled());
        assertEq(h.eligibleAtSettlement(), 5);
        assertEq(h.fullScans(), 2);
    }

    function testFallbackRestartsForNewlyEligibleWinnerBehindCursor() public {
        AdlFallbackHarness.Slot[] memory slots = new AdlFallbackHarness.Slot[](4);
        slots[1] = AdlFallbackHarness.Slot(5, false);
        slots[3] = AdlFallbackHarness.Slot(10, true);
        AdlFallbackHarness h = new AdlFallbackHarness(slots, 5, 2);
        h.completeAdl(1);
        h.closeWinner(3);
        h.refreshEligibility(uint256(1) << 1);
        h.completeAdl(1);
        assertEq(h.cursor(), 4);
        assertEq(h.remaining(), 5);
        h.completeAdl(1);
        h.completeAdl(1);
        assertEq(h.remaining(), 0);
        assertFalse(h.settled());
    }

    function testFallbackProofUsesReducedSizeAfterPartialWinnerClose() public {
        AdlFallbackHarness.Slot[] memory slots = new AdlFallbackHarness.Slot[](4);
        slots[2] = AdlFallbackHarness.Slot(10, true);
        AdlFallbackHarness h = new AdlFallbackHarness(slots, 8, 0);
        h.completeAdl(1);
        h.closeWinnerSize(2, 4);
        h.completeAdl(1);
        assertTrue(h.settled());
        assertEq(h.eligibleAtSettlement(), 6);
        assertEq(h.slot(2).size, 6);
    }

    function _assertSchedule(AdlScheduleHarness h, AdlScheduleHarness.Snapshot memory s, Oracle memory o) private view {
        assertEq(h.done(), o.size);
        assertEq(h.entryRemoved(), o.entry);
        assertEq(h.scheduledValue(), o.scheduled);
        assertEq(h.actualValue(), o.actual);
        assertEq(h.relief(), o.relief);
        assertEq(o.actual, s.longTarget ? o.scheduled + o.relief : o.scheduled - o.relief);
        (uint256 size, uint256 entry, uint256 value, bool longTarget) = h.snapshot();
        assertEq(size, s.size);
        assertEq(entry, s.entry);
        assertEq(value, s.value);
        assertEq(longTarget, s.longTarget);
    }

    function _eligible(AdlFallbackHarness.Slot[] memory slots) private pure returns (uint256 total) {
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].eligible) total += slots[i].size;
        }
    }

    function _next(uint256 entropy) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(entropy)));
    }
}
