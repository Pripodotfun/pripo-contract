// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FixedPointMath as F} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Exact fixed-denominator schedules and rational ADL eligibility.
library AdlMath {
    function chunk(uint256 total, uint256 size, uint256 beforeSize, uint256 afterSize) internal pure returns (uint256) {
        return Math.mulDiv(total, afterSize, size) - Math.mulDiv(total, beforeSize, size);
    }

    function marginShare(int256 margin, uint256 amount, uint256 size) internal pure returns (int256) {
        uint256 magnitude =
            Math.mulDiv(F.abs(margin), amount, size, margin < 0 ? Math.Rounding.Ceil : Math.Rounding.Floor);
        return margin < 0 ? -F.toInt(magnitude) : F.toInt(magnitude);
    }

    function winnerEntry(uint256 entry, uint256 amount, uint256 size, bool longWinner) internal pure returns (uint256) {
        return Math.mulDiv(entry, amount, size, longWinner ? Math.Rounding.Floor : Math.Rounding.Ceil);
    }

    function positiveAtRatio(uint256 entry, uint256 size, uint256 value, uint256 selectedSize, bool longWinner)
        internal
        pure
        returns (bool)
    {
        (uint256 entryHi, uint256 entryLo) = Math.mul512(entry, selectedSize);
        (uint256 valueHi, uint256 valueLo) = Math.mul512(value, size);
        return longWinner
            ? valueHi > entryHi || (valueHi == entryHi && valueLo > entryLo)
            : entryHi > valueHi || (entryHi == valueHi && entryLo > valueLo);
    }

    /// @dev The entry/quote bounds of an admitted market fit entry*WAD and the intermediate large-collateral quotient.
    ///      Scores beyond uint256 saturate; zero collateral has highest priority.
    function score(uint256 profit, uint256 entry, uint256 collateral) internal pure returns (uint256) {
        if (collateral == 0) return type(uint256).max;
        uint256 scaledEntry = entry * F.WAD;
        if (collateral > type(uint128).max) return Math.mulDiv(profit, scaledEntry, collateral) / collateral;
        uint256 denominator = collateral * collateral;
        // Only the high limb is needed to detect an overflowing quotient; mulDiv computes the exact score below.
        // slither-disable-next-line unused-return
        (uint256 high,) = Math.mul512(profit, scaledEntry);
        if (high >= denominator) return type(uint256).max;
        return Math.mulDiv(profit, scaledEntry, denominator);
    }
}
