// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {PositionBook as Book} from "../../src/market/PositionBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Executable accounting vectors for the proposed pending-ADL schedule, before runtime integration.
contract AdlValueScheduleTest is Test {
    function testShrinkingPositionEntryAllocationDisagreesWithFrozenPartialBudget() public pure {
        uint256 originalEntry = 402;
        uint256 originalSize = 4;
        uint256 pendingSize = 2;
        uint256 selectedEntry = Curve.closedEntryCost(originalEntry, pendingSize, originalSize);
        assertEq(selectedEntry, 201);
        uint256 first = Curve.closedEntryCost(originalEntry, 1, originalSize);
        uint256 second = Curve.closedEntryCost(originalEntry - first, 1, originalSize - 1);
        assertEq(first + second, 200);

        uint256 budget = 3;
        uint256 shortValue = selectedEntry + budget;
        assertEq(shortValue - first - second, 4, "shrinking allocation exceeds the short's frozen loss budget");
        uint256 firstFixed = _chunk(selectedEntry, pendingSize, 0, 1);
        uint256 secondFixed = _chunk(selectedEntry, pendingSize, 1, 1);
        assertEq(firstFixed + secondFixed, selectedEntry);
        assertEq(shortValue - firstFixed - secondFixed, budget);
        assertEq(originalEntry - firstFixed - secondFixed, 201, "unselected exposure keeps its original allocation");
    }

    function testFuzzFrozenEntryAndValueConserveAcrossChunkings(
        uint80 entrySeed,
        uint96 sizeSeed,
        uint96 selectedSeed,
        uint80 valueSeed,
        uint256 cuts,
        bool longTarget
    ) public pure {
        uint256 originalEntry = bound(entrySeed, 1, 1e24);
        uint256 originalSize = bound(sizeSeed, 1, 1e24);
        uint256 selectedSize = bound(selectedSeed, 1, originalSize);
        uint256 selectedEntry = Curve.closedEntryCost(originalEntry, selectedSize, originalSize);
        uint256 totalValue = bound(valueSeed, 0, 1e24);
        uint256 done;
        uint256 removedEntry;
        uint256 pairedValue;
        int256 loss;
        for (uint256 i; i < 8 && done < selectedSize; ++i) {
            uint256 left = selectedSize - done;
            uint256 amount = i == 7 ? left : 1 + cuts % left;
            uint256 entry = _chunk(selectedEntry, selectedSize, done, amount);
            uint256 value = _chunk(totalValue, selectedSize, done, amount);
            removedEntry += entry;
            pairedValue += value;
            loss += longTarget ? F.toInt(entry) - F.toInt(value) : F.toInt(value) - F.toInt(entry);
            done += amount;
            assertEq(removedEntry, Math.mulDiv(selectedEntry, done, selectedSize));
            assertEq(pairedValue, Math.mulDiv(totalValue, done, selectedSize));
            cuts = uint256(keccak256(abi.encode(cuts, i)));
        }
        assertEq(done, selectedSize);
        assertEq(removedEntry, selectedEntry);
        assertEq(pairedValue, totalValue);
        assertEq(originalEntry - removedEntry, originalEntry - selectedEntry);
        assertEq(
            loss,
            longTarget ? F.toInt(selectedEntry) - F.toInt(totalValue) : F.toInt(totalValue) - F.toInt(selectedEntry)
        );
    }

    function testFuzzOneWeiCoversScheduledZeroProfit(
        uint96 valueSeed,
        uint64 sizeSeed,
        uint64 winnerSizeSeed,
        uint64 offsetSeed,
        uint64 chunkSeed,
        bool longWinner
    ) public pure {
        uint256 totalValue = bound(valueSeed, 1, 1e24);
        uint256 size = bound(sizeSeed, 1, 1e18);
        uint256 winnerSize = bound(winnerSizeSeed, 1, 1e18);
        uint256 done = bound(offsetSeed, 0, size - 1);
        uint256 amount = bound(chunkSeed, 1, Math.min(size - done, winnerSize));
        uint256 wholeValue =
            Math.mulDiv(totalValue, winnerSize, size, longWinner ? Math.Rounding.Ceil : Math.Rounding.Floor);
        uint256 winnerEntry = longWinner ? wholeValue - 1 : wholeValue + 1;
        if (longWinner) assertLt(winnerEntry * size, totalValue * winnerSize);
        else assertGt(winnerEntry * size, totalValue * winnerSize);
        uint256 entry =
            Math.mulDiv(winnerEntry, amount, winnerSize, longWinner ? Math.Rounding.Floor : Math.Rounding.Ceil);
        uint256 value = _chunk(totalValue, size, done, amount);
        int256 profit = longWinner ? F.toInt(value) - F.toInt(entry) : F.toInt(entry) - F.toInt(value);
        assertGe(profit, 0, "winner-favouring entry rounding absorbs the scheduled value's rounding error");
        uint256 topUp = profit == 0 ? 1 : 0;
        assertGe(profit + F.toInt(topUp), 1);
        assertLe(topUp, 1);
    }

    function testPositivePaidProfitCanRemainBelowExactProfit() public pure {
        uint256 value = _chunk(4, 3, 2, 1);
        uint256 entry = Math.mulDiv(5, 1, 2, Math.Rounding.Ceil);
        uint256 profit = entry - value;
        assertEq(profit, 1, "positive rounded profit receives no top-up");
        // Exact short profit is (5/2 - 4/3) * 1 = 7/6 quote wei.
        assertLt(profit * 6, 7, "the former rounded-profit >= exact-profit invariant no longer holds");
    }

    function testRealizableReliefChangesActualValueSumAndMirrorsForShort() public pure {
        uint256 first = _chunk(10, 3, 0, 1);
        uint256 last = _chunk(10, 3, 1, 2);
        assertEq(first + last, 10);
        uint256 longActual = Math.max(first, 4) + last;
        assertEq(longActual, 11, "long target relief raises actual proceeds above the base schedule");
        uint256 shortActual = Math.min(first, 2) + last;
        assertEq(shortActual, 9, "short target relief lowers actual cost below the base schedule");
    }

    function testSixtyFourChunksCanLeaveSufficientEligibleSizeUnmatched() public pure {
        uint256 required = 65;
        uint256 matched;
        uint256 totalValue;
        assertLe(required + 1, Book.MAX_POSITIONS, "loser and all 65 winners fit the existing book");
        for (uint256 i; i < 64; ++i) {
            uint256 value = _chunk(required, required, matched, 1);
            assertGt(uint256(2) * required, required, "each one-unit short is exactly profitable");
            assertGt(uint256(2) - value, 0);
            totalValue += value;
            ++matched;
        }
        assertEq(totalValue, 64);
        assertEq(required - matched, 1);
        uint256 eligibleRemainingSize = 1;
        assertGe(eligibleRemainingSize, required - matched, "the chunk limit is not eligible-size exhaustion");
    }

    function _chunk(uint256 total, uint256 size, uint256 done, uint256 amount) private pure returns (uint256) {
        return Math.mulDiv(total, done + amount, size) - Math.mulDiv(total, done, size);
    }
}
