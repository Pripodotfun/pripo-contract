// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {Test} from "forge-std/Test.sol";

contract FixedPointMathTest is Test {
    function test_SignedCeilingRoundsTowardProtocol() public pure {
        assertEq(F.ceilWad(1), 1);
        assertEq(F.ceilWad(-1), 0);
        assertEq(F.ceilWad(1e18 + 1), 2);
        assertEq(F.ceilWad(-1e18 - 1), -1);
        assertEq(F.ceilWad(0), 0);
        assertEq(F.usdcToWad(1_000_000), 1e18);
    }

    function test_AbsHandlesSignedMinimum() public pure {
        assertEq(F.abs(type(int256).min), uint256(1) << 255);
    }

    function testFuzz_CeilingRemainderBound(int128 valueHi) public pure {
        int256 owed = F.ceilWad(valueHi);
        int256 rounding = owed * 1e18 - int256(valueHi);
        assertGe(rounding, 0);
        assertLt(rounding, 1e18);
    }

    function test_RejectsUnrepresentableSignedHighProduct() public {
        vm.expectRevert(E.MathOverflow.selector);
        this.multiply(2, type(int256).max);
    }

    function multiply(uint256 size, int256 index) external pure returns (int256) {
        return F.signedProduct(size, index);
    }
}
