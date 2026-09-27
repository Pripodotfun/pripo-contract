// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {FixedPointMath as F} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Two-sided funding indexes with exact weighted obligations and explicit settlement rounding.
/// @dev All functions are accounting primitives. The caller applies returned funding to margin/debt atomically.
library FundingMath {
    function oracleRate(uint256 markPrice, uint256 indexPrice, uint32 period, uint64 cap)
        internal
        pure
        returns (int256)
    {
        if (indexPrice == 0 || period == 0) revert E.InvalidFundingParameters();
        bool positive = markPrice >= indexPrice;
        uint256 diff = positive ? markPrice - indexPrice : indexPrice - markPrice;
        uint256 magnitude = Math.min(Math.mulDiv(diff, F.WAD, indexPrice) / period, cap);
        return positive ? F.toInt(magnitude) : -F.toInt(magnitude);
    }

    function skewRate(uint256 longs, uint256 shorts, uint256 coefficient, uint32 period, uint64 cap)
        internal
        pure
        returns (int256)
    {
        if (period == 0 || coefficient > F.WAD) revert E.InvalidFundingParameters();
        if (longs == 0 || shorts == 0) return 0;
        bool positive = longs >= shorts;
        uint256 diff = positive ? longs - shorts : shorts - longs;
        uint256 magnitude = Math.min(Math.mulDiv(coefficient, diff, longs + shorts) / period, cap);
        return positive ? F.toInt(magnitude) : -F.toInt(magnitude);
    }

    /// @dev Accrue before changing either side's size. A zero rate also represents Degraded mode.
    function accrue(
        T.FundingState memory f,
        uint256 longs,
        uint256 shorts,
        int256 rate,
        uint256 referencePrice,
        uint64 currentBlock,
        uint16 receiveCapX
    ) internal pure returns (T.FundingState memory) {
        if (currentBlock < f.lastBlock) revert E.TimeWentBackwards(f.lastBlock, currentBlock);
        uint256 elapsed = currentBlock - f.lastBlock;
        f.lastBlock = currentBlock;
        if (elapsed == 0 || longs == 0 || shorts == 0 || rate == 0) return f;
        if (referencePrice == 0 || receiveCapX == 0) revert E.InvalidFundingParameters();
        uint256 perUnit = Math.mulDiv(F.abs(rate), referencePrice, F.WAD) * elapsed;
        (uint256 paySize, uint256 recvSize) = rate > 0 ? (longs, shorts) : (shorts, longs);
        uint256 payHi = F.highProduct(perUnit, paySize);
        uint256 perRecv = Math.min(payHi / recvSize, perUnit * receiveCapX);
        uint256 recvHi = F.highProduct(perRecv, recvSize);
        f.remainderHi += payHi - recvHi;
        if (rate > 0) {
            f.longIndex += F.toInt(perUnit);
            f.shortIndex -= F.toInt(perRecv);
        } else {
            f.shortIndex += F.toInt(perUnit);
            f.longIndex -= F.toInt(perRecv);
        }
        return f;
    }

    /// @notice Returns the signed WAD margin debit and the refreshed snapshot; does not modify a margin balance.
    function settle(T.FundingState memory f, int256 size, int256 previousIndex)
        internal
        pure
        returns (T.FundingState memory, int256 owed, int256 currentIndex)
    {
        if (size == 0) revert E.InvalidSize();
        currentIndex = size > 0 ? f.longIndex : f.shortIndex;
        int256 deltaHi = F.signedProduct(F.abs(size), currentIndex - previousIndex);
        owed = F.ceilWad(deltaHi);
        int256 rounding = F.signedProduct(F.WAD, owed) - deltaHi;
        if (rounding < 0 || F.abs(rounding) >= F.WAD) revert E.AccountingInvariant();
        f.roundingHi += F.toUint(rounding);
        if (size > 0) f.longWeighted += deltaHi;
        else f.shortWeighted += deltaHi;
        return (f, owed, currentIndex);
    }

    /// @notice Replace the weighted contribution AFTER settling the old size to its current side index.
    /// @dev Caller updates side totals and the position's new snapshot in the same operation.
    function changeSize(T.FundingState memory f, int256 oldSize, int256 newSize)
        internal
        pure
        returns (T.FundingState memory)
    {
        if (oldSize > 0) f.longWeighted -= F.signedProduct(F.abs(oldSize), f.longIndex);
        else if (oldSize < 0) f.shortWeighted -= F.signedProduct(F.abs(oldSize), f.shortIndex);
        if (newSize > 0) f.longWeighted += F.signedProduct(F.abs(newSize), f.longIndex);
        else if (newSize < 0) f.shortWeighted += F.signedProduct(F.abs(newSize), f.shortIndex);
        return f;
    }

    function pending(T.FundingState memory f, uint256 longs, uint256 shorts) internal pure returns (int256) {
        return (F.signedProduct(longs, f.longIndex) - f.longWeighted)
            + (F.signedProduct(shorts, f.shortIndex) - f.shortWeighted);
    }

    /// @notice Exact accrued surplus in WAD squared, after reserving signed pending obligations.
    function surplus(T.FundingState memory f, int256 pool, uint256 longs, uint256 shorts)
        internal
        pure
        returns (uint256)
    {
        int256 value = F.signedProduct(F.WAD, pool) + pending(f, longs, shorts);
        int256 expected = F.toInt(f.remainderHi) + F.toInt(f.roundingHi) - F.toInt(f.sweptHi);
        if (value < 0 || value != expected) revert E.AccountingInvariant();
        return F.toUint(value);
    }

    /// @notice Caller credits exactly `amount` to market insurance; sweeping does not transfer ERC-20s.
    function sweep(T.FundingState memory f, int256 pool, uint256 longs, uint256 shorts)
        internal
        pure
        returns (T.FundingState memory, int256 newPool, uint256 amount)
    {
        uint256 availableHi = surplus(f, pool, longs, shorts);
        // Preserve the fractional remainder, and book only a whole quote-WAD amount as swept.
        uint256 sweptHi = availableHi - availableHi % F.WAD;
        amount = sweptHi / F.WAD;
        f.sweptHi += sweptHi;
        return (f, pool - F.toInt(amount), amount);
    }
}
