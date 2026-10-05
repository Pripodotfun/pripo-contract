// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../types/PripoTypes.sol";
import {CurveMath as Curve} from "./CurveMath.sol";
import {FixedPointMath as F} from "./FixedPointMath.sol";
import {RiskMath as Risk} from "./RiskMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library LiquidationPriceMath {
    /// @notice Inclusive integer index threshold, preserving floor-long / ceil-short and strict maintenance.
    function indexPrice(int256 size, uint256 entry, uint256 collateral, uint256 maintenance)
        internal
        pure
        returns (uint256)
    {
        if (size > 0) {
            if (collateral >= entry + maintenance) return 0;
            return Math.mulDiv(entry + maintenance - collateral, F.WAD, F.abs(size), Math.Rounding.Ceil) - 1;
        }
        return Math.mulDiv(entry + collateral - maintenance, F.WAD, F.abs(size)) + 1;
    }

    /// @notice Closest adverse TWAP crossing within reachable side-cap marks. Zero means no crossing.
    /// @dev The current observation must be healthy. Rounding can produce multiple one-wei crossings;
    /// this searches intervals without assuming that rounded close PnL is monotonic.
    function twapPrice(
        T.AmmState memory a,
        int256 size,
        uint256 entry,
        uint256 collateral,
        uint256 maintenance,
        uint256 current,
        uint16 capBps
    ) internal pure returns (uint256) {
        bool isLong = size > 0;
        if (isLong && collateral >= entry + maintenance) return 0;
        uint256 target = isLong ? entry + maintenance - collateral : entry + collateral - maintenance;
        uint256 cap = Risk.sideCap(a.baseAtSeed, capBps);
        uint256 endpoint = isLong ? a.baseAtSeed + cap : a.baseAtSeed - cap;
        uint256 limit = Math.mulDiv(Math.ceilDiv(a.k, endpoint), F.WAD, endpoint);
        if (isLong ? current <= limit : current >= limit) return 0;
        uint256[96] memory left;
        uint256[96] memory right;
        left[0] = isLong ? limit : current + 1;
        right[0] = isLong ? current - 1 : limit;
        uint256 count = 1;
        uint256 amount = F.abs(size);
        while (count != 0) {
            --count;
            uint256 lo = left[count];
            uint256 hi = right[count];
            uint256 nearPrice = isLong ? hi : lo;
            uint256 nearBase = _base(a.k, nearPrice);
            a.baseReserve = nearBase;
            a.quoteReserve = Math.ceilDiv(a.k, nearBase);
            uint256 value = Curve.quoteExit(a, size).quoteAmount;
            if (isLong ? value < target : value > target) return nearPrice;
            if (lo == hi) continue;
            uint256 farBase = _base(a.k, isLong ? lo : hi);
            if (farBase == nearBase) continue;
            // ceil(A)-ceil(B) lies between floor(A-B) and ceil(A-B).
            // The unrounded rational is monotonic in the virtual base, unlike the rounded difference.
            uint256 denominator = farBase * (isLong ? farBase + amount : farBase - amount);
            uint256 bound = Math.mulDiv(a.k, amount, denominator, isLong ? Math.Rounding.Floor : Math.Rounding.Ceil);
            if (isLong ? bound >= target : bound <= target) continue;
            uint256 mid = (lo + hi) / 2;
            left[count] = isLong ? lo : mid + 1;
            right[count++] = isLong ? mid : hi;
            left[count] = isLong ? mid + 1 : lo;
            right[count++] = isLong ? hi : mid;
        }
        return 0;
    }

    function _base(uint256 k, uint256 price) private pure returns (uint256) {
        return Math.sqrt(Math.mulDiv(k, F.WAD, price));
    }
}
