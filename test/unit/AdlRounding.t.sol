// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {MarketAdl as Adl} from "../../src/market/MarketAdl.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
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

    function testFuzzGuaranteedSliceFundsProfitAndCollateral(
        uint96 sizeSeed,
        uint80 priceSeed,
        uint80 profitSeed,
        uint96 sliceSeed,
        uint80 debtSeed,
        uint8 collateralKind,
        bool long
    ) public pure {
        uint256 size = bound(sizeSeed, 1, 1e24);
        uint256 price = bound(priceSeed, 1e18, 1e24);
        uint256 fullQuote = Math.mulDiv(size, price, F.WAD, long ? Math.Rounding.Floor : Math.Rounding.Ceil);
        uint256 profit = bound(profitSeed, 1, fullQuote);
        int256 collateral;
        if (collateralKind % 5 == 1) collateral = F.toInt(profit);
        if (collateralKind % 5 == 2) collateral = -F.toInt(profit);
        if (collateralKind % 5 == 3) collateral = -F.toInt(bound(debtSeed, 1, profit));
        if (collateralKind % 5 == 4) collateral = -F.toInt(profit) + F.toInt(bound(debtSeed, 0, Math.min(profit, 8)));
        uint256 entry = long ? fullQuote - profit : fullQuote + profit;
        Adl.Candidate memory c = Adl.Candidate({
            user: address(1),
            position: T.Position(long ? F.toInt(size) : -F.toInt(size), 0, entry, 0),
            margin: collateral,
            score: 0,
            price: price,
            eligible: true
        });
        uint256 minimum = Adl.minimumSlice(c);
        assertGe(minimum, 1);
        assertLe(minimum, size);
        uint256 amount = bound(sliceSeed, minimum, size);
        uint256 quote = Math.mulDiv(amount, price, F.WAD, long ? Math.Rounding.Floor : Math.Rounding.Ceil);
        uint256 cost = Curve.closedEntryCost(entry, amount, size);
        int256 pnl = long ? F.toInt(quote) - F.toInt(cost) : F.toInt(cost) - F.toInt(quote);
        assertGt(pnl, 0, "every size at or above the threshold must retain positive profit");
        int256 payout = Adl.marginShare(collateral, amount, size) + pnl;
        assertGe(payout, 0, "slice must pay its allocated collateral debt");
        if (payout > 0) assertGe(collateral + pnl, payout, "vault must be able to release the payout");
        if (collateral == -F.toInt(profit)) assertEq(minimum, size);
    }

    function testRedistributionFundsNegativeCollateralOnBothSlices() public pure {
        Adl.Candidate[] memory candidates = new Adl.Candidate[](2);
        candidates[0] = _candidate(address(1), 1e18, 100.01e18, -0.01e18);
        candidates[1] = _candidate(address(2), 1e18, 100.01e18, -0.01e18);
        Adl.Plan memory p = _initial(candidates);
        assertTrue(Adl._rebalance(p, candidates, 1, 100));
        assertEq(p.count, 2);
        assertEq(F.abs(p.matches[0].size) + F.abs(p.matches[1].size), 1e18 + 100);
        assertEq(F.abs(p.matches[1].size), 1e18);
        for (uint256 i; i < p.count; ++i) {
            int256 pnl = F.toInt(p.matches[i].entry) - F.toInt(p.matches[i].quote);
            assertGt(pnl, 0);
            assertGe(p.matches[i].margin + pnl, 0);
        }
        assertEq(p.quote, p.matches[0].quote + p.matches[1].quote);
    }

    function testRedistributionCannotReleaseProfitOverRemainingDebt() public pure {
        Adl.Candidate[] memory candidates = new Adl.Candidate[](2);
        candidates[0] = _candidate(address(1), 1e18, 100.01e18, -0.005e18);
        candidates[1] = _candidate(address(2), 1e18, 100.01e18, -0.005e18);
        Adl.Plan memory p = _initial(candidates);
        assertFalse(Adl._rebalance(p, candidates, 1, 1));
        assertEq(p.count, 1);
        assertEq(p.matches[0].size, -1e18);
    }

    function testWholeMatchReplacementPreservesPriorityOrder() public pure {
        Adl.Candidate[] memory candidates = new Adl.Candidate[](3);
        candidates[0] = _candidate(address(1), 100, 10_001, 0);
        candidates[1] = _candidate(address(2), 100, 10_001, 0);
        candidates[2] = _candidate(address(3), 200, 20_100, 0);
        Adl.Plan memory p = _initial(candidates);
        // The second match cannot be resized. Replace that full match plus the remainder with the final candidate.
        p.matches[1] = Adl.Match(address(2), -100, 10_001, 10_000, 0, 1);
        p.count = 2;
        p.quote = 20_000;
        assertTrue(Adl._rebalance(p, candidates, 2, 1));
        assertEq(p.count, 2);
        assertEq(p.matches[0].user, address(1));
        assertEq(p.matches[1].user, address(3));
        assertEq(p.matches[1].size, -101);
        assertEq(p.quote, 20_100);
        assertGt(p.matches[1].entry, p.matches[1].quote);
    }

    function testUnallocatableRedistributionLeavesPlanUnchanged() public pure {
        Adl.Candidate[] memory candidates = new Adl.Candidate[](2);
        candidates[0] = _candidate(address(1), 100, 10_001, 0);
        candidates[1] = _candidate(address(2), 100, 10_001, 0);
        Adl.Plan memory p = _initial(candidates);
        bytes32 before = keccak256(abi.encode(p));
        assertFalse(Adl._rebalance(p, candidates, 1, 1));
        assertEq(p.rebalanceChecks, 1);
        p.rebalanceChecks = 0;
        assertEq(keccak256(abi.encode(p)), before);
    }

    function testExactPriorSliceCanSucceedBelowConservativeBound() public pure {
        Adl.Candidate[] memory candidates = new Adl.Candidate[](2);
        candidates[0] = _candidate(address(1), 100, 12_000, -2_000);
        candidates[1] = _candidate(address(2), 100, 10_001, 0);
        Adl.Plan memory p = _initial(candidates);
        assertEq(Adl.minimumSlice(candidates[0]), 100);
        assertTrue(Adl._rebalance(p, candidates, 1, 1));
        assertEq(p.count, 2);
        assertEq(p.matches[0].size, -1);
        assertEq(p.matches[1].size, -100);
        assertEq(p.matches[0].margin + F.toInt(p.matches[0].entry) - F.toInt(p.matches[0].quote), 0);
        assertEq(p.quote, 10_100);
    }

    function testFullBookUnallocatableSearchGasBound() public {
        _searchGas(false);
    }

    function testFullBookZeroEquitySearchGasBound() public {
        _searchGas(true);
    }

    function _searchGas(bool zeroEquity) internal {
        Adl.Candidate[] memory candidates = new Adl.Candidate[](127);
        for (uint256 i; i < candidates.length; ++i) {
            candidates[i] = _candidate(
                address(uint160(i + 1)), 100, zeroEquity ? 10_150 : 10_001, zeroEquity ? -int256(150) : int256(0)
            );
        }
        Adl.Plan memory p = _initial(candidates);
        for (uint256 i = 1; i < 63; ++i) {
            p.matches[i] =
                Adl.Match(candidates[i].user, -100, candidates[i].position.entryCost, 10_000, candidates[i].margin, i);
        }
        p.count = 63;
        p.quote = 630_000;
        uint256 gasBefore = gasleft();
        for (uint256 i = 63; i < candidates.length; ++i) {
            assertFalse(Adl._rebalance(p, candidates, i, 1));
        }
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("512-check capped redistribution search gas", used);
        assertLt(used, 3_000_000, "bounded redistribution preflight budget");
        assertEq(p.rebalanceChecks, Adl.MAX_REBALANCE_CHECKS);
        assertEq(p.count, 63);
        assertEq(p.quote, 630_000);
    }

    function _candidate(address user, uint256 size, uint256 entry, int256 margin)
        internal
        pure
        returns (Adl.Candidate memory)
    {
        return Adl.Candidate({
            user: user,
            position: T.Position(-F.toInt(size), 0, entry, 0),
            margin: margin,
            score: 0,
            price: 100e18,
            eligible: true
        });
    }

    function _initial(Adl.Candidate[] memory candidates) internal pure returns (Adl.Plan memory p) {
        p.matches = new Adl.Match[](candidates.length);
        Adl.Candidate memory c = candidates[0];
        p.matches[0] =
            Adl.Match(c.user, c.position.size, c.position.entryCost, F.abs(c.position.size) * 100, c.margin, 0);
        p.count = 1;
        p.quote = p.matches[0].quote;
    }
}
