// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AdlMath as A} from "../../src/libraries/AdlMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Pending accounting model using production schedule math; it does not execute market or vault transitions.
contract AdlScheduleHarness {
    struct Snapshot {
        uint256 size;
        uint256 entry;
        uint256 value;
        bool longTarget;
    }

    struct Chunk {
        uint256 size;
        uint256 realizableValue;
        uint256 bookedProfit;
    }

    event AdlZeroProfit(uint256 indexed chunk);

    Snapshot public snapshot;
    uint256 public immutable bookCap;
    uint256 public immutable allowanceFromCoverage;
    uint256 public immutable allowanceFromReserve;
    uint256 public immutable lossCoverage;
    uint256 public immutable reserveRemaining;
    uint256 public allowance;
    uint256 public allowanceConsumed;
    uint256 public chunksMatched;
    uint256 public done;
    uint256 public entryRemoved;
    uint256 public scheduledValue;
    uint256 public actualValue;
    uint256 public relief;

    constructor(Snapshot memory initial, uint256 cap, uint256 coverage, uint256 reserve) {
        require(initial.size != 0 && cap != 0);
        snapshot = initial;
        bookCap = cap;
        allowanceFromCoverage = Math.min(cap, coverage);
        allowanceFromReserve = Math.min(cap - allowanceFromCoverage, reserve);
        allowance = allowanceFromCoverage + allowanceFromReserve;
        lossCoverage = coverage - allowanceFromCoverage;
        reserveRemaining = reserve - allowanceFromReserve;
    }

    function continueAdl(Chunk[] calldata chunks) external returns (uint256[] memory paid) {
        require(chunks.length != 0 && chunks.length <= 64);
        require(chunksMatched + chunks.length <= bookCap);
        paid = new uint256[](chunks.length);
        Snapshot memory s = snapshot;
        for (uint256 i; i < chunks.length; ++i) {
            Chunk calldata c = chunks[i];
            require(c.size != 0 && done + c.size <= s.size);
            uint256 value = A.chunk(s.value, s.size, done, done + c.size);
            uint256 actual = s.longTarget ? Math.max(value, c.realizableValue) : Math.min(value, c.realizableValue);
            relief += s.longTarget ? actual - value : value - actual;
            actualValue += actual;
            scheduledValue += value;
            entryRemoved += A.chunk(s.entry, s.size, done, done + c.size);
            done += c.size;
            paid[i] = c.bookedProfit;
            if (c.bookedProfit == 0) {
                if (allowance != 0) {
                    --allowance;
                    ++allowanceConsumed;
                    paid[i] = 1;
                } else {
                    emit AdlZeroProfit(chunksMatched);
                }
            }
            ++chunksMatched;
        }
    }
}

/// @notice Test-only stable-slot fallback model. Eligibility is supplied by fixtures, not market pricing.
/// No new positions are allowed during pending; closing a winner clears only its own slot.
contract AdlFallbackHarness {
    struct Slot {
        uint256 size;
        bool eligible;
    }

    Slot[] private slots;
    uint256 public cursor;
    uint256 public remaining;
    uint256 public inspected;
    uint256 public matched;
    uint256 public closedOutside;
    uint256 public fullScans;
    uint256 public eligibleAtSettlement;
    bool public settled;

    constructor(Slot[] memory initial, uint256 size, uint256 start) {
        require(initial.length != 0 && size != 0 && start <= initial.length);
        for (uint256 i; i < initial.length; ++i) {
            slots.push(initial[i]);
        }
        remaining = size;
        cursor = start;
    }

    function slot(uint256 index) external view returns (Slot memory) {
        return slots[index];
    }

    function book() external view returns (Slot[] memory) {
        return slots;
    }

    function closeWinner(uint256 index) external {
        require(!settled && remaining != 0);
        closedOutside += slots[index].size;
        delete slots[index];
    }

    function closeWinnerSize(uint256 index, uint256 amount) external {
        require(!settled && remaining != 0 && amount != 0 && amount <= slots[index].size);
        closedOutside += amount;
        slots[index].size -= amount;
        if (slots[index].size == 0) delete slots[index];
    }

    /// @dev Models refreshed eligibility after another close changes realizable pricing.
    function refreshEligibility(uint256 mask) external {
        require(!settled && remaining != 0);
        for (uint256 i; i < slots.length; ++i) {
            slots[i].eligible = slots[i].size != 0 && mask & (uint256(1) << i) != 0;
        }
    }

    function completeAdl(uint256 maxIterations) external {
        require(maxIterations != 0 && maxIterations <= 64 && !settled && remaining != 0);
        // Only a fresh scan in this call can authorize settlement.
        uint256 eligibleSize;
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i].eligible) eligibleSize += slots[i].size;
        }
        ++fullScans;
        if (eligibleSize < remaining) {
            eligibleAtSettlement = eligibleSize;
            settled = true;
            return;
        }
        for (uint256 i; i < maxIterations && remaining != 0; ++i) {
            if (cursor == slots.length) cursor = 0;
            Slot storage s = slots[cursor];
            ++cursor;
            ++inspected;
            if (!s.eligible || s.size == 0) continue;
            uint256 amount = Math.min(s.size, remaining);
            s.size -= amount;
            remaining -= amount;
            matched += amount;
            if (s.size == 0) delete slots[cursor - 1];
        }
    }
}
