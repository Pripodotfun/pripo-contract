// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LiquidationMath as L} from "../../src/libraries/LiquidationMath.sol";
import {Test} from "forge-std/Test.sol";

contract LiquidationMathTest is Test {
    function testStrictThresholdAndFractionalQuoteBoundary() public pure {
        assertEq(L.fraction(500e18, 100e18, true, false), 1e18);
        assertEq(L.fraction(500e18 + 1, 100e18, true, false), 0.5e18);
        assertEq(L.fraction(100e18, 100e18, false, false), 1e18);
        assertEq(L.fraction(100e18 + 1, 100e18, false, false), 0.5e18);
        assertEq(L.fraction(50_000e18 * 1e18 + 1, 1, true, false), 0.5e18);
    }

    function testDegradedHalfAndFinalBaseWei() public pure {
        assertEq(L.fraction(2, 100e18, true, true), 0.5e18);
        assertEq(L.fraction(1, 100e18, true, true), 1e18);
        assertEq(L.penalty(1, 150), 1);
        assertEq(L.penalty(1_000e18, 150), 15e18);
    }
}
