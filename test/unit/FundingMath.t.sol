// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {FundingMath} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {FundingHarness} from "../helpers/FundingHarness.sol";
import {Test} from "forge-std/Test.sol";

contract FundingMathTest is Test {
    FundingHarness h;

    function setUp() public {
        h = new FundingHarness();
    }

    function pair(int256 longSize, int256 shortSize) internal {
        h.resize(0, longSize);
        h.resize(1, -shortSize);
    }

    function checkCash() internal view {
        assertEq(h.cash(), h.marginTotal() + h.pool() + int256(h.insurance()));
        T.FundingState memory f = h.state();
        assertEq(int256(h.surplus()), int256(f.remainderHi) + int256(f.roundingHi) - int256(f.sweptHi));
    }

    function test_PayerFirstDoesNotSweepReceiverPayment() public {
        pair(1e18, 1e18);
        h.accrue(10e18, 1);
        assertEq(h.settle(0), 10e18);
        assertEq(h.pool(), 10e18);
        assertEq(h.pending(), -10e36);
        assertEq(h.sweep(), 0);
        checkCash();
        assertEq(h.settle(1), -10e18);
        assertEq(h.pool(), 0);
        assertEq(h.pending(), 0);
        checkCash();
    }

    function test_ReceiverFirstAllowsNegativePool() public {
        pair(1e18, 1e18);
        h.accrue(10e18, 1);
        assertEq(h.settle(1), -10e18);
        assertEq(h.pool(), -10e18);
        assertEq(h.sweep(), 0);
        checkCash();
        h.settle(0);
        assertEq(h.pool(), 0);
        checkCash();
    }

    function test_ReceiptCapAndEarlySurplusSweep() public {
        pair(100e18, 1e18);
        h.accrue(1e15, 1);
        assertEq(h.sweep(), 0.09e18);
        assertEq(h.pool(), -0.09e18);
        checkCash();
        assertEq(h.settle(1), -0.01e18);
        assertEq(h.settle(0), 0.1e18);
        assertEq(h.pool(), 0);
        assertEq(h.sweep(), 0);
        assertEq(h.insurance(), 0.09e18);
        checkCash();
    }

    function test_UncappedDivisionRemainder() public {
        pair(1e18, 3e18);
        h.accrue(1e18, 1);
        assertEq(h.state().remainderHi, 1e18);
        assertEq(h.settle(0), 1e18);
        assertEq(h.settle(1), -(1e18 - 1));
        assertEq(h.sweep(), 1);
        checkCash();
    }

    function test_TenFractionalAccrualsCarryFiveWei() public {
        pair(0.5e18, 1e18);
        for (uint256 i; i < 10; ++i) {
            h.accrue(1e15 + 1, 1);
        }
        assertEq(h.settle(0), 5_000_000_000_000_005);
        assertEq(h.settle(1), -5_000_000_000_000_000);
        assertEq(h.state().roundingHi, 0);
        assertEq(h.sweep(), 5);
        assertEq(h.sweep(), 0);
        checkCash();
    }

    function test_SweptRoundingCanExceedAccrualRemainder() public {
        pair(0.5e18, 0.5e18);
        h.accrue(1, 1);
        assertEq(h.settle(1), 0);
        assertEq(h.settle(0), 1);
        assertEq(h.state().remainderHi, 0);
        assertEq(h.state().roundingHi, 1e18);
        assertEq(h.sweep(), 1);
        assertGt(h.state().sweptHi, h.state().remainderHi);
        checkCash();
    }

    function test_NoAccrualWithEmptyCounterSideOrZeroRate() public {
        h.resize(0, 1e18);
        h.accrue(1e15, 30);
        assertEq(h.state().lastBlock, 30);
        assertEq(h.state().longIndex, 0);
        h.resize(1, -1e18);
        h.accrue(0, 10);
        assertEq(h.state().longIndex, 0);
        assertEq(h.state().lastBlock, 40);
    }

    function test_RateReversalPartialCloseAndSideChange() public {
        pair(2e18, 1e18);
        h.accrue(1e15, 10);
        h.resize(0, 1e18);
        h.resize(2, -3e18);
        assertEq(h.settle(2), 0); // New position does not receive historical funding.
        h.accrue(-3e14, 11);
        h.resize(0, -1e18);
        h.accrue(1e15, 10); // Empty long side: zero additional accrual.
        h.resize(0, 0);
        h.resize(1, 0);
        h.resize(2, 0);
        assertEq(h.state().longWeighted, 0);
        assertEq(h.state().shortWeighted, 0);
        assertEq(h.pending(), 0);
        h.sweep();
        assertEq(h.pool(), 0);
        checkCash();
    }

    function test_RatesHaveExpectedSignsAndCaps() public pure {
        assertEq(FundingMath.oracleRate(110e18, 100e18, 100, 1e14), 1e14);
        assertEq(FundingMath.oracleRate(90e18, 100e18, 100, 1e14), -1e14);
        assertEq(FundingMath.oracleRate(100e18, 100e18, 12000, 1e14), 0);
        assertGt(FundingMath.skewRate(100e18, 60e18, 0.05e18, 12000, 1e14), 0);
        assertLt(FundingMath.skewRate(60e18, 100e18, 0.05e18, 12000, 1e14), 0);
        assertEq(FundingMath.skewRate(1e18, 0, 0.05e18, 12000, 1e14), 0);
    }
}
