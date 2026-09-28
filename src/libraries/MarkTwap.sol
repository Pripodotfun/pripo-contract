// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Block-weighted mark observations. At most one observation per block; supports windows up to 600 blocks.
library MarkTwap {
    uint256 internal constant CAPACITY = 601;

    struct Observation {
        uint64 blockNumber;
        uint256 cumulative;
        uint256 price;
    }

    struct State {
        Observation[601] observations;
        uint16 next;
        uint16 count;
        uint64 firstBlock;
        uint256 initialPrice;
    }

    function initialize(State storage s, uint256 price, uint64 atBlock) public {
        if (price == 0 || s.count != 0) revert E.InvalidConfiguration();
        s.observations[0] = Observation(atBlock, 0, price);
        s.next = 1;
        s.count = 1;
        s.firstBlock = atBlock;
        s.initialPrice = price;
    }

    function write(State storage s, uint256 price, uint64 atBlock) public {
        if (price == 0 || s.count == 0) revert E.InvalidConfiguration();
        uint256 lastSlot = (uint256(s.next) + CAPACITY - 1) % CAPACITY;
        Observation storage last = s.observations[lastSlot];
        if (atBlock < last.blockNumber) revert E.TimeWentBackwards(last.blockNumber, atBlock);
        if (atBlock == last.blockNumber) {
            last.price = price;
            return;
        }
        uint256 cumulative = last.cumulative + last.price * (atBlock - last.blockNumber);
        s.observations[s.next] = Observation(atBlock, cumulative, price);
        s.next = SafeCast.toUint16((uint256(s.next) + 1) % CAPACITY);
        if (s.count < CAPACITY) s.count++;
    }

    function consult(State storage s, uint32 window, uint64 atBlock) public view returns (uint256) {
        if (window == 0 || window >= CAPACITY || s.count == 0) revert E.InvalidConfiguration();
        Observation memory last = s.observations[(uint256(s.next) + CAPACITY - 1) % CAPACITY];
        if (atBlock < last.blockNumber) revert E.TimeWentBackwards(last.blockNumber, atBlock);
        if (atBlock == s.firstBlock) return s.initialPrice;
        uint64 start = atBlock > window ? atBlock - window : 0;
        if (start < s.firstBlock) start = s.firstBlock;
        uint256 oldest = s.count == CAPACITY ? s.next : 0;
        // Binary search the chronologically ordered ring for the observation at or before start.
        uint256 lo = 0;
        uint256 hi = s.count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (s.observations[(oldest + mid) % CAPACITY].blockNumber <= start) lo = mid;
            else hi = mid - 1;
        }
        Observation memory prior = s.observations[(oldest + lo) % CAPACITY];
        if (prior.blockNumber > start) revert E.AccountingInvariant();
        uint256 startCumulative = prior.cumulative + prior.price * (start - prior.blockNumber);
        uint256 endCumulative = last.cumulative + last.price * (atBlock - last.blockNumber);
        return (endCumulative - startCumulative) / (atBlock - start);
    }
}
