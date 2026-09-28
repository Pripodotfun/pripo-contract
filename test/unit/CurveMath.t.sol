// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {Test} from "forge-std/Test.sol";

contract CurveMathTest is Test {
    function test_DustExitAndValuationRemainDefined() public pure {
        T.AmmState memory a = CurveMath.seed(0.1e18, 100e18);
        T.Fill memory exitFill = CurveMath.quoteExit(a, 1);
        assertEq(exitFill.quoteAmount, 0);
        assertEq(exitFill.baseReserve, a.baseReserve + 1);
        assertEq(CurveMath.realizablePnl(a, 1, 1), -1);
    }

    function applyFill(T.AmmState memory a, T.Fill memory f) internal pure returns (T.AmmState memory) {
        a.baseReserve = f.baseReserve;
        a.quoteReserve = f.quoteReserve;
        return a;
    }

    function test_ExactSpecSequenceAndClearing() public pure {
        T.AmmState memory a = CurveMath.seed(100e18, 12_000e18);
        T.Fill memory first = CurveMath.quote(a, 20e18);
        assertEq(first.quoteAmount, 2_400e18);
        a = applyFill(a, first);
        a.entryCostNet = 2_400e18;
        assertEq(CurveMath.clearing(a), 0);
        assertEq(CurveMath.realizablePnl(a, 20e18, 2_400e18), 0);
        T.Fill memory second = CurveMath.quote(a, 20e18);
        assertEq(second.quoteAmount, 3_600e18);
        a = applyFill(a, second);
        a.entryCostNet += 3_600e18;
        assertEq(CurveMath.realizablePnl(a, 20e18, 2_400e18), 1_200e18);
        a = applyFill(a, CurveMath.quote(a, -20e18));
        a.entryCostNet -= 2_400e18;
        assertEq(CurveMath.clearing(a), -1_200e18);
        assertEq(CurveMath.realizablePnl(a, 20e18, 3_600e18), -1_200e18);
        a = applyFill(a, CurveMath.quote(a, -20e18));
        a.entryCostNet = 0;
        assertEq(CurveMath.clearing(a), 0);
        assertEq(a.quoteReserve, a.curveBase);
        assertEq(a.baseReserve, a.baseAtSeed);
    }

    function test_PartialEntryCostConservesFinalRemainder() public pure {
        uint256 first = CurveMath.closedEntryCost(7, 1, 3);
        uint256 second = CurveMath.closedEntryCost(7 - first, 1, 2);
        uint256 last = CurveMath.closedEntryCost(7 - first - second, 1, 1);
        assertEq(first, 2);
        assertEq(second, 2);
        assertEq(last, 3);
        assertEq(first + second + last, 7);
    }

    function testFuzz_RoundTripRestoresReserves(uint96 depthSeed, uint64 priceSeed, bool buy) public pure {
        uint256 depth = bound(depthSeed, 1e18, 1e28);
        uint256 price = bound(priceSeed, 1e6, 1e19);
        T.AmmState memory a = CurveMath.seed(price, depth);
        uint256 size = a.baseReserve / 10;
        int256 signedSize = buy ? int256(size) : -int256(size);
        T.Fill memory entry = CurveMath.quote(a, signedSize);
        T.AmmState memory changed = applyFill(a, entry);
        T.Fill memory exitFill = CurveMath.quote(changed, -signedSize);
        assertEq(entry.quoteAmount, exitFill.quoteAmount);
        assertEq(exitFill.quoteReserve, depth);
        assertEq(exitFill.baseReserve, changed.baseAtSeed);
    }

    function testFuzz_LargerLongCostsMorePerBase(uint80 depthSeed, uint16 fractionSeed) public pure {
        T.AmmState memory a = CurveMath.seed(100e18, bound(depthSeed, 1e20, 1e24));
        uint256 fraction = bound(fractionSeed, 10, 100);
        int256 small = int256(a.baseReserve / fraction);
        T.Fill memory smallFill = CurveMath.quote(a, small);
        T.Fill memory largeFill = CurveMath.quote(a, small * 2);
        assertGt(largeFill.avgPrice, smallFill.avgPrice);
        assertGt(largeFill.newMark, smallFill.newMark);
    }

    function test_RejectsExhaustedAndZeroSize() public {
        T.AmmState memory a = CurveMath.seed(100e18, 10_000e18);
        vm.expectRevert(E.ReserveExhausted.selector);
        this.quoteExternal(a, int256(a.baseReserve));
        vm.expectRevert(E.InvalidSize.selector);
        this.quoteExternal(a, 0);
    }

    function test_RejectsMalformedReserveState() public {
        T.AmmState memory a = CurveMath.seed(100e18, 10_000e18);
        ++a.quoteReserve;
        vm.expectRevert(E.InvalidReserves.selector);
        this.quoteExternal(a, 1e18);
    }

    function test_RejectsZeroQuoteDustTrade() public {
        T.AmmState memory a = CurveMath.seed(1, 1e18);
        vm.expectRevert(E.ZeroQuote.selector);
        this.quoteExternal(a, -1);
    }

    function quoteExternal(T.AmmState memory a, int256 size) external pure returns (T.Fill memory) {
        return CurveMath.quote(a, size);
    }
}
