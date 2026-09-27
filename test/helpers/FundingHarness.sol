// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {FundingMath} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";

/// @dev Test-only accounting harness. Uses signed synthetic margin; it is not a vault or market implementation.
contract FundingHarness {
    struct Account {
        int256 size;
        int256 snapshot;
        int256 margin;
    }
    T.FundingState internal funding;
    mapping(uint256 => Account) public accounts;
    uint256 public longs;
    uint256 public shorts;
    int256 public pool;
    uint256 public insurance;
    int256 public marginTotal;
    int256 public cash;
    uint256 public settlementCount;

    function state() external view returns (T.FundingState memory) {
        return funding;
    }

    function resize(uint256 user, int256 newSize) public {
        Account storage a = accounts[user];
        int256 oldSize = a.size;
        if (oldSize != 0) {
            settle(user);
        } else if (newSize != 0) {
            a.margin = 1e30;
            marginTotal += 1e30;
            cash += 1e30;
        }
        funding = FundingMath.changeSize(funding, oldSize, newSize);
        if (oldSize > 0) longs -= uint256(oldSize);
        else if (oldSize < 0) shorts -= F.abs(oldSize);
        if (newSize > 0) longs += uint256(newSize);
        else if (newSize < 0) shorts += F.abs(newSize);
        a.size = newSize;
        a.snapshot = newSize > 0 ? funding.longIndex : newSize < 0 ? funding.shortIndex : int256(0);
        if (newSize == 0) {
            // Withdraw remaining synthetic margin so closed accounts have no margin or funding snapshot.
            marginTotal -= a.margin;
            cash -= a.margin;
            a.margin = 0;
        }
    }

    function accrue(int256 perUnitPerBlock, uint64 blocksElapsed) public {
        funding =
            FundingMath.accrue(funding, longs, shorts, perUnitPerBlock, F.WAD, funding.lastBlock + blocksElapsed, 10);
    }

    function settle(uint256 user) public returns (int256 owed) {
        Account storage a = accounts[user];
        if (a.size == 0) return 0;
        (funding, owed, a.snapshot) = FundingMath.settle(funding, a.size, a.snapshot);
        a.margin -= owed;
        marginTotal -= owed;
        pool += owed;
        ++settlementCount;
    }

    function sweep() public returns (uint256 amount) {
        (funding, pool, amount) = FundingMath.sweep(funding, pool, longs, shorts);
        insurance += amount;
    }

    function pending() external view returns (int256) {
        return FundingMath.pending(funding, longs, shorts);
    }

    function surplus() external view returns (uint256) {
        return FundingMath.surplus(funding, pool, longs, shorts);
    }
}
