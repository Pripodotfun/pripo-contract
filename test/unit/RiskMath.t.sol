// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract RiskMathTest is Test {
    function test_DerivedCapsMatchSpec() public pure {
        assertEq(RiskMath.sideCapBps(20), 128);
        assertEq(RiskMath.sideCapBps(5), 557);
        assertEq(RiskMath.sideCapBps(3), 1010);
        assertEq(RiskMath.sideCapBps(2), 1715);
    }

    function testFuzz_CapIsLargestIntegerSatisfyingBound(uint16 leverageSeed) public pure {
        uint16 leverage = uint16(bound(leverageSeed, 2, 1000));
        uint256 cap = RiskMath.sideCapBps(leverage);
        assertGe(uint256(leverage) * (10000 - cap) ** 2, uint256(leverage - 1) * (10000 + cap) ** 2);
        assertLt(uint256(leverage) * (9999 - cap) ** 2, uint256(leverage - 1) * (10001 + cap) ** 2);
    }

    function test_DepthUsesAppliedIntegerCapAndRoundsUp() public pure {
        assertEq(RiskMath.minimumDepth(5_000e18, 20, 128), 7_812_500e18);
        uint256 depth = RiskMath.minimumDepth(2_000e18, 10, 1010);
        assertGe(depth * 1010, 20_000e18 * 10000);
        assertLt((depth - 1) * 1010, 20_000e18 * 10000);
        assertEq(Math.ceilDiv(depth, 1e18), 198020);
    }

    function test_ShortImpactMarginCorrectsOldCounterexample() public pure {
        T.AmmState memory a = CurveMath.seed(100e18, 10_000e18);
        uint256 proceeds = CurveMath.quote(a, -1e18).quoteAmount;
        uint256 buyback = RiskMath.worstClose(a, false, 1e18, 2500);
        uint256 margin = RiskMath.initialMargin(a, -1e18, proceeds, 5, 250, 2500);
        uint256 buffer = Math.mulDiv(proceeds, 250, 10000, Math.Rounding.Ceil);
        assertEq(margin, buyback - proceeds + buffer);
        assertGt(margin, 78e18);
        assertGt(margin, Math.ceilDiv(proceeds, 5));
        uint256 launchMargin = RiskMath.initialMargin(a, -1e18, proceeds, 5, 250, 557);
        assertEq(launchMargin, Math.ceilDiv(proceeds, 5));
    }

    function testFuzz_MarginCoversWorstLossAndBuffer(uint64 sizeSeed, bool isLong) public pure {
        T.AmmState memory a = CurveMath.seed(100e18, 10_000e18);
        uint256 size = bound(sizeSeed, 1e10, RiskMath.sideCap(a.baseAtSeed, 557));
        int256 signedSize = isLong ? int256(size) : -int256(size);
        uint256 entry = CurveMath.quote(a, signedSize).quoteAmount;
        uint256 worst = RiskMath.worstClose(a, isLong, size, 557);
        int256 loss = isLong ? int256(entry) - int256(worst) : int256(worst) - int256(entry);
        uint256 margin = RiskMath.initialMargin(a, signedSize, entry, 5, 250, 557);
        uint256 buffer = Math.mulDiv(entry, 250, 10000, Math.Rounding.Ceil);
        assertGe(int256(margin) - int256(buffer), loss);
        assertGe(margin * 5, entry);
    }

    function test_RejectsInvalidLeverage() public {
        vm.expectRevert(abi.encodeWithSelector(E.InvalidLeverage.selector, 1));
        this.capExternal(1);
    }

    function capExternal(uint16 leverage) external pure returns (uint16) {
        return RiskMath.sideCapBps(leverage);
    }
}
