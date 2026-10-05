// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PripoTypes as T} from "../types/PripoTypes.sol";
import {CurveMath as Curve} from "./CurveMath.sol";
import {FeeMath as Fees} from "./FeeMath.sol";
import {FixedPointMath as F} from "./FixedPointMath.sol";
import {RiskMath as Risk} from "./RiskMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Exact maximum additional size, including rounded fills, margin, fees and post-trade caps.
library OpenCapacityMath {
    struct Context {
        T.AmmState amm;
        T.MarketConfig config;
        uint256 longs;
        uint256 shorts;
        uint256 size;
        uint256 entry;
        int256 collateral;
        uint256 free;
        uint256 oiCap;
        bool isLong;
    }

    struct Point {
        uint256 entry;
        uint256 worst;
        uint256 mark;
        uint256 longs;
        uint256 shorts;
    }

    /// @dev Descending interval search: rounding and skew discounts need not be monotonic.
    /// An interval is discarded only if a lower bound proves every member infeasible.
    /// Validated seed base <= 1e28 gives at most 94 bisection levels; siblings use a fixed stack.
    function maximum(Context memory c) internal pure returns (uint256) {
        uint256 cap = Risk.sideCap(c.amm.baseAtSeed, c.config.sideCapBps);
        if (c.longs > cap || c.shorts > cap) return 0;
        uint256 upper = cap - (c.isLong ? c.longs : c.shorts);
        if (upper == 0) return 0;
        uint256[96] memory left;
        uint256[96] memory right;
        left[0] = 1;
        right[0] = upper;
        uint256 count = 1;
        while (count != 0) {
            --count;
            uint256 lo = left[count];
            uint256 hi = right[count];
            Point memory last = _point(c, hi);
            if (_allowed(c, last, hi)) return hi;
            if (lo == hi || _impossible(c, lo, hi, last)) continue;
            uint256 mid = (lo + hi) / 2;
            left[count] = lo;
            right[count++] = mid;
            left[count] = mid + 1;
            right[count++] = hi;
        }
        return 0;
    }

    function _point(Context memory c, uint256 amount) private pure returns (Point memory p) {
        // The exit quote admits zero-quote dust for the search; _allowed excludes it from actual opens.
        T.Fill memory fill = Curve.quoteExit(c.amm, c.isLong ? -F.toInt(amount) : F.toInt(amount));
        p.entry = c.entry + fill.quoteAmount;
        p.worst = Risk.worstClose(c.amm, c.isLong, c.size + amount, c.config.sideCapBps);
        p.mark = fill.newMark;
        p.longs = c.longs + (c.isLong ? amount : 0);
        p.shorts = c.shorts + (c.isLong ? 0 : amount);
    }

    function _allowed(Context memory c, Point memory p, uint256 amount) private pure returns (bool) {
        if (p.entry == c.entry || !_caps(c, p.longs, p.shorts, c.size + amount, p.mark)) return false;
        uint256 loss = c.isLong ? p.entry - Math.min(p.entry, p.worst) : p.worst - Math.min(p.entry, p.worst);
        uint256 required = _required(c, p.entry, p.worst, loss);
        uint256 beforeSkew = _skew(c.longs, c.shorts);
        uint256 fee =
            Fees.takerFee(p.entry - c.entry, c.config.takerFeeBps, beforeSkew, _skew(p.longs, p.shorts) < beforeSkew);
        return _affordable(c, required, fee);
    }

    function _impossible(Context memory c, uint256 lo, uint256 hi, Point memory last) private pure returns (bool) {
        if (last.entry == c.entry) return true;
        Point memory first = _point(c, lo);
        uint256 minMark = c.isLong ? first.mark : last.mark;
        if (!_caps(c, first.longs, first.shorts, c.size + lo, minMark)) return true;
        // Entry and worst-close value each increase with size. Cross-endpoint loss is a lower bound.
        uint256 loss = c.isLong
            ? first.entry - Math.min(first.entry, last.worst)
            : first.worst - Math.min(first.worst, last.entry);
        uint256 required = _required(c, first.entry, first.worst, loss);
        uint256 own = c.isLong ? c.longs : c.shorts;
        uint256 other = c.isLong ? c.shorts : c.longs;
        uint256 balance = other > own ? other - own : 0;
        uint256 best = Math.max(lo, Math.min(hi, balance));
        uint256 beforeSkew = _skew(own, other);
        bool discountPossible = _skew(own + best, other) < beforeSkew;
        uint256 fee = Fees.takerFee(first.entry - c.entry, c.config.takerFeeBps, beforeSkew, discountPossible);
        return !_affordable(c, required, fee);
    }

    function _required(Context memory c, uint256 entry, uint256 worst, uint256 loss) private pure returns (uint256) {
        // The protected floor dominates the full impact minimum. Execution also takes the leverage maximum.
        return Math.max(
            Math.ceilDiv(entry, c.config.maxLeverageX),
            loss + Math.mulDiv(entry, c.config.mmrBps, F.BPS, Math.Rounding.Ceil)
                + Math.mulDiv(worst, c.config.takerFeeBps, F.BPS, Math.Rounding.Ceil)
        );
    }

    function _caps(Context memory c, uint256 longs, uint256 shorts, uint256 size, uint256 mark)
        private
        pure
        returns (bool)
    {
        return Math.mulDiv(Math.max(longs, shorts), mark, F.WAD, Math.Rounding.Ceil) <= c.oiCap
            && Math.mulDiv(size, mark, F.WAD, Math.Rounding.Ceil) <= 2_000e18;
    }

    function _affordable(Context memory c, uint256 required, uint256 fee) private pure returns (bool) {
        return fee <= c.free && c.collateral + F.toInt(c.free - fee) >= F.toInt(required);
    }

    function _skew(uint256 longs, uint256 shorts) private pure returns (uint256) {
        if (longs + shorts == 0) return 0;
        return Math.mulDiv(longs > shorts ? longs - shorts : shorts - longs, F.WAD, longs + shorts);
    }
}
