// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {Test} from "forge-std/Test.sol";

contract FundingCapacityMathTest is Test {
    function testClampedGapIsDiscardedAndZeroHeadroomStopsBothIndexes() public pure {
        T.FundingState memory f;
        f = Funding.accrueCapped(f, 1e18, 1e18, 1e18, 1e18, 1_000_000, 10, 5e18);
        assertEq(f.longIndex, 5e18);
        assertEq(f.shortIndex, -5e18);
        assertEq(f.lastBlock, 1_000_000);
        f = Funding.accrueCapped(f, 1e18, 1e18, 1e18, 1e18, 2_000_000, 10, 0);
        assertEq(f.longIndex, 5e18);
        assertEq(f.shortIndex, -5e18);
        assertEq(f.lastBlock, 2_000_000);
        f = Funding.accrueCapped(f, 1e18, 1e18, 1e18, 1e18, 2_000_001, 10, 100e18);
        assertEq(f.longIndex, 6e18, "only one new block accrues after headroom is restored");
        assertEq(f.shortIndex, -6e18);
    }

    function testClampsBeforeElapsedMultiplicationCouldOverflow() public pure {
        T.FundingState memory f;
        f = Funding.accrueCapped(f, 1e18, 1e18, type(int256).max, 1e18, type(uint64).max, 10, 7);
        assertEq(f.longIndex, 7);
        assertEq(f.shortIndex, -7);
        assertEq(f.lastBlock, type(uint64).max);
    }

    function testFuzzEveryRoundedPayerDebitFitsItsOwnCapacity(uint256 seed, uint64 elapsedSeed, bool longsPay)
        public
        pure
    {
        uint256[8] memory sizes;
        uint256[8] memory capacities;
        uint256 paySize;
        uint256 limit = type(uint256).max;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            sizes[i] = 1 + seed % 1e24;
            capacities[i] = (seed >> 96) % 1e30;
            uint256 candidate = capacities[i] * 1e18 / sizes[i];
            if (candidate < limit) limit = candidate;
            paySize += sizes[i];
        }
        uint256 receiveSize = 1 + (seed >> 128) % 1e24;
        uint64 elapsed = uint64(bound(elapsedSeed, 1, type(uint64).max));
        (uint256 longs, uint256 shorts) = longsPay ? (paySize, receiveSize) : (receiveSize, paySize);
        T.FundingState memory f;
        f = Funding.accrueCapped(f, longs, shorts, longsPay ? int256(1e18) : -int256(1e18), 1e18, elapsed, 10, limit);
        uint256 expected = uint256(elapsed) * 1e18;
        if (expected > limit) expected = limit;
        assertEq(longsPay ? f.longIndex : f.shortIndex, int256(expected));

        int256 pool;
        int256 owed;
        // Receiver settles first. Its advance is covered exclusively by the modeled payers' capacities.
        (f, owed,) = Funding.settle(f, longsPay ? -int256(receiveSize) : int256(receiveSize), 0);
        assertLe(owed, 0);
        pool += owed;
        uint256 paid;
        for (uint256 i; i < 8; ++i) {
            (f, owed,) = Funding.settle(f, longsPay ? int256(sizes[i]) : -int256(sizes[i]), 0);
            assertGe(owed, 0);
            assertLe(uint256(owed), capacities[i]);
            paid += uint256(owed);
            pool += owed;
        }
        assertGe(pool, 0);
        assertEq(Funding.pending(f, longs, shorts), 0);
        assertEq(Funding.surplus(f, pool, longs, shorts), uint256(pool) * 1e18);
        assertLe(uint256(pool), paid);
    }
}
