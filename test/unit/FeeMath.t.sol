// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {Test} from "forge-std/Test.sol";

contract FeeMathTest is Test {
    function test_DefaultFeeAndReferralShares() public pure {
        uint256 total = FeeMath.takerFee(10_000e18, 8, 0, false);
        assertEq(total, 8e18);
        T.FeeBreakdown memory f = FeeMath.split(total, 3000, 3000, 1000, true);
        assertEq(f.creator, 2.4e18);
        assertEq(f.insurance, 2.4e18);
        assertEq(f.referral, 0.8e18);
        assertEq(f.protocol, 2.4e18);
        f = FeeMath.split(total, 3000, 3000, 1000, false);
        assertEq(f.referral, 0);
        assertEq(f.protocol, 3.2e18);
    }

    function test_DiscountOnlyWhenReducingSkew() public pure {
        assertEq(FeeMath.takerFee(10_000e18, 8, 1e18, true), 4e18);
        assertEq(FeeMath.takerFee(10_000e18, 8, 1e18, false), 8e18);
        assertEq(FeeMath.takerFee(10_000e18, 8, 0.6e18, true), 5.6e18);
    }

    function testFuzz_SplitsNeverCreateOrLoseQuote(uint128 total, bool hasReferrer) public pure {
        T.FeeBreakdown memory f = FeeMath.split(total, 3000, 3000, 1000, hasReferrer);
        assertEq(f.protocol + f.creator + f.insurance + f.referral, total);
        if (!hasReferrer) assertEq(f.referral, 0);
    }

    function test_ChargesOneWeiAndAssignsSplitDust() public pure {
        uint256 total = FeeMath.takerFee(1, 8, 0, false);
        assertEq(total, 1);
        T.FeeBreakdown memory f = FeeMath.split(total, 3000, 3000, 1000, true);
        assertEq(f.protocol, 1);
        assertEq(f.creator + f.insurance + f.referral, 0);
    }
}
