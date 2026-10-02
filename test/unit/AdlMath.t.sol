// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AdlMath as A} from "../../src/libraries/AdlMath.sol";
import {Test} from "forge-std/Test.sol";

contract AdlMathTest is Test {
    function testFuzzExactEligibilityWithOverflowingCrossProducts(uint64 sizeSeed, uint64 selectedSeed, bool above)
        public
        pure
    {
        // Both products exceed 256 bits. Entry differs from the common exact ratio by one quote wei.
        uint256 size = uint256(sizeSeed) + (uint256(1) << 64);
        uint256 selected = uint256(selectedSeed) + (uint256(1) << 64);
        uint256 ratio = uint256(1) << 160;
        uint256 entry = ratio * size;
        uint256 value = ratio * selected;
        assertFalse(A.positiveAtRatio(entry, size, value, selected, true));
        assertFalse(A.positiveAtRatio(entry, size, value, selected, false));
        entry = above ? entry + 1 : entry - 1;
        assertEq(A.positiveAtRatio(entry, size, value, selected, false), above);
        assertEq(A.positiveAtRatio(entry, size, value, selected, true), !above);
    }

    function testFuzzScoreMatchesBoundedIntegerReference(uint64 profit, uint64 entry, uint64 collateralSeed)
        public
        pure
    {
        uint256 collateral = uint256(collateralSeed) + 1;
        uint256 expected = uint256(profit) * entry * 1e18 / (collateral * collateral);
        assertEq(A.score(profit, entry, collateral), expected);
    }

    function testScoreZeroCollateralSaturationAndLargeCollateral() public pure {
        assertEq(A.score(1, 1, 0), type(uint256).max);
        assertEq(A.score(1e56, 2_000e18, 1), type(uint256).max);
        uint256 collateral = uint256(1) << 129;
        // Cancel one exact power of two before the independent reference calculation.
        uint256 profit = uint256(1) << 180;
        uint256 entry = 2_000e18;
        uint256 expected = (uint256(1) << 51) * entry * 1e18 / collateral;
        assertEq(A.score(profit, entry, collateral), expected);
        assertEq(A.score(1e56, entry, type(uint256).max), 0);
    }

    function testSignedMarginAndWinnerEntryRounding() public pure {
        assertEq(A.marginShare(11, 1, 3), 3);
        assertEq(A.marginShare(-11, 1, 3), -4);
        assertEq(A.marginShare(-11, 3, 3), -11);
        assertEq(A.winnerEntry(11, 1, 3, true), 3);
        assertEq(A.winnerEntry(11, 1, 3, false), 4);
        assertEq(A.winnerEntry(11, 3, 3, false), 11);
    }
}
