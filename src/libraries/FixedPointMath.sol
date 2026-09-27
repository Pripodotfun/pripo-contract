// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Unit conversions and checked signed arithmetic for the accounting libraries.
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant USDC_SCALE = 1e12;

    function abs(int256 value) internal pure returns (uint256) {
        // Also defined for int256.min; conversion back to the symmetric signed domain is checked separately.
        // Both casts use nonnegative branch values; the +1 handles int256.min without negating it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }

    function toInt(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) revert E.MathOverflow();
        // Range checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(value);
    }

    function toUint(int256 value) internal pure returns (uint256) {
        if (value < 0) revert E.MathOverflow();
        // Sign checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(value);
    }

    /// @dev The stored accounting domain is [-int256.max, int256.max].
    function signedProduct(uint256 size, int256 index) internal pure returns (int256) {
        uint256 magnitude = abs(index);
        if (magnitude != 0 && size > uint256(type(int256).max) / magnitude) revert E.MathOverflow();
        int256 result = toInt(size * magnitude);
        return index < 0 ? -result : result;
    }

    function highProduct(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y != 0 && x > uint256(type(int256).max) / y) revert E.MathOverflow();
        return x * y;
    }

    /// @notice Signed ceiling: payers round up; receiver receipts round down in absolute amount.
    function ceilWad(int256 valueHi) internal pure returns (int256) {
        if (valueHi < 0) return -toInt(abs(valueHi) / WAD);
        return toInt(Math.ceilDiv(abs(valueHi), WAD));
    }

    function usdcToWad(uint256 rawAmount) internal pure returns (uint256) {
        return rawAmount * USDC_SCALE;
    }
}
