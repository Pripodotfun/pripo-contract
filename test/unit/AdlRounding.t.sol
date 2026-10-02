// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract AdlRoundingTest is Test {
    function testRoundingAgainstLongTargetCanExceedCoverageBudget() public pure {
        uint256 size = 3;
        uint256 entry = 10;
        uint256 margin = 1;
        uint256 capacity = 1;
        uint256 boundary = Math.mulDiv(entry - margin - capacity, F.WAD, size, Math.Rounding.Ceil);
        uint256 pairedQuote;
        for (uint256 i; i < size; ++i) {
            uint256 winnerEntry = 4;
            assertGt(winnerEntry * F.WAD, boundary, "each one-base-wei short is exactly profitable");
            uint256 value = Math.mulDiv(1, boundary, F.WAD, Math.Rounding.Floor);
            assertGt(winnerEntry - value, 0);
            pairedQuote += value;
        }
        assertGe(size * boundary, (entry - margin - capacity) * F.WAD);
        assertEq(pairedQuote, 6);
        assertEq(entry - margin - pairedQuote, 3);
        assertGt(entry - margin - pairedQuote, capacity, "rounded matches exceed the planned coverage");
    }

    function testRoundingAgainstShortTargetCanExceedCoverageBudget() public pure {
        uint256 size = 3;
        uint256 entry = 8;
        uint256 margin = 1;
        uint256 capacity = 1;
        uint256 boundary = Math.mulDiv(entry + margin + capacity, F.WAD, size, Math.Rounding.Floor);
        uint256 pairedQuote;
        for (uint256 i; i < size; ++i) {
            uint256 winnerEntry = 3;
            assertLt(winnerEntry * F.WAD, boundary, "each one-base-wei long is exactly profitable");
            uint256 value = Math.mulDiv(1, boundary, F.WAD, Math.Rounding.Ceil);
            assertGt(value - winnerEntry, 0);
            pairedQuote += value;
        }
        assertLe(size * boundary, (entry + margin + capacity) * F.WAD);
        assertEq(pairedQuote, 12);
        assertEq(pairedQuote - entry - margin, 3);
        assertGt(pairedQuote - entry - margin, capacity, "rounded matches exceed the planned coverage");
    }

    function testFuzzWinnerFavouringRoundingAlwaysPaysPositiveProfit(
        uint96 sizeSeed,
        uint80 priceSeed,
        uint80 profitSeed,
        uint96 sliceSeed,
        bool long
    ) public pure {
        uint256 size = bound(sizeSeed, 1, 1e24);
        uint256 price = bound(priceSeed, 1e18, 1e24);
        uint256 wholeValue = Math.mulDiv(size, price, F.WAD, long ? Math.Rounding.Ceil : Math.Rounding.Floor);
        uint256 gap = bound(profitSeed, 1, Math.min(wholeValue, 1e24));
        uint256 entry = long ? wholeValue - gap : wholeValue + gap;
        uint256 amount = bound(sliceSeed, 1, size);
        uint256 allocatedEntry = Math.mulDiv(entry, amount, size, long ? Math.Rounding.Floor : Math.Rounding.Ceil);
        uint256 value = Math.mulDiv(amount, price, F.WAD, long ? Math.Rounding.Ceil : Math.Rounding.Floor);
        uint256 profit = long ? value - allocatedEntry : allocatedEntry - value;
        uint256 exactNumerator = long ? size * price - entry * F.WAD : entry * F.WAD - size * price;
        assertGt(exactNumerator, 0);
        assertGe(profit * size * F.WAD, exactNumerator * amount, "rounded chunk profit covers exact chunk profit");
        assertGe(profit, 1, "positive exact profit cannot round to zero under these directions");
    }

    function testExactPositiveShortSliceCanBookOneWeiLoss() public pure {
        uint256 size = 1e18;
        uint256 entry = 100.2e18;
        uint256 price = 100.015e18;
        uint256 amount = 1;
        assertGt(entry * F.WAD, price * size, "whole position has strictly positive exact PnL");
        uint256 fullQuote = Math.mulDiv(size, price, F.WAD, Math.Rounding.Ceil);
        assertGt(entry, fullQuote, "whole position also has positive rounded PnL");

        uint256 cost = Curve.closedEntryCost(entry, amount, size);
        uint256 quote = Math.mulDiv(amount, price, F.WAD, Math.Rounding.Ceil);
        int256 pnl = F.toInt(cost) - F.toInt(quote);
        assertEq(cost, 100);
        assertEq(quote, 101);
        assertEq(pnl, -1, "independent entry and quote rounding can turn a profit into a loss");
        assertEq(pnl + 1, 0, "one wei cannot turn this booked loss into positive paid profit");
    }
}
