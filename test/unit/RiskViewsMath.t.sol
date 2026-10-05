// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CurveMath as Curve} from "../../src/libraries/CurveMath.sol";
import {FeeMath as Fees} from "../../src/libraries/FeeMath.sol";
import {FixedPointMath as F} from "../../src/libraries/FixedPointMath.sol";
import {LiquidationPriceMath as Prices} from "../../src/libraries/LiquidationPriceMath.sol";
import {OpenCapacityMath as Capacity} from "../../src/libraries/OpenCapacityMath.sol";
import {RiskMath as Risk} from "../../src/libraries/RiskMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract RiskViewsMathTest is Test {
    function testFuzzMaximumMatchesEverySizeInSmallRoundedBook(uint256 seed) public pure {
        Capacity.Context memory c;
        c.config.sideCapBps = 1715;
        c.config.maxLeverageX = 2;
        c.config.mmrBps = 1500;
        c.config.takerFeeBps = 8;
        uint256 base = 128;
        uint256 quote = 1 + seed % 1000;
        c.amm = T.AmmState(base, quote, base * quote, base, quote, 0);
        c.longs = (seed >> 10) % 21;
        c.shorts = (seed >> 20) % 21;
        c.amm.baseReserve = base + c.shorts - c.longs;
        c.amm.quoteReserve = Math.ceilDiv(c.amm.k, c.amm.baseReserve);
        c.isLong = (seed >> 30) % 2 == 0;
        c.size = (seed >> 31) % ((c.isLong ? c.longs : c.shorts) + 1);
        c.entry = c.size == 0 ? 0 : 1 + (seed >> 40) % 200;
        c.collateral = F.toInt((seed >> 50) % 300) - 20;
        c.free = (seed >> 60) % 200;
        c.oiCap = 1 + (seed >> 70) % 500;
        uint256 cap = Risk.sideCap(base, c.config.sideCapBps);
        uint256 expected;
        for (uint256 amount = 1; amount <= cap - (c.isLong ? c.longs : c.shorts); ++amount) {
            if (_executable(c, amount)) expected = amount;
        }
        assertEq(Capacity.maximum(c), expected);
    }

    function testFuzzIndexThresholdAndAdjacentPrice(uint128 entrySeed, uint96 sizeSeed, uint128 marginSeed, bool long)
        public
        pure
    {
        uint256 entry = 1 + uint256(entrySeed) % 2_000e18;
        uint256 amount = 1 + uint256(sizeSeed) % 1e28;
        uint256 maintenance = Math.mulDiv(entry, 250, 10_000, Math.Rounding.Ceil);
        uint256 margin = uint256(marginSeed) % (entry + maintenance);
        int256 size = long ? F.toInt(amount) : -F.toInt(amount);
        uint256 price = Prices.indexPrice(size, entry, margin, maintenance);
        assertTrue(_indexUnhealthy(size, entry, margin, maintenance, price));
        assertFalse(_indexUnhealthy(size, entry, margin, maintenance, long ? price + 1 : price - 1));
    }

    function testFuzzTwapNearestCrossingMatchesEveryReachablePrice(uint128 seed, bool long) public pure {
        T.AmmState memory a = Curve.seed(100, 10_000);
        uint256 amount = 1e18 + uint256(seed) % 10e18;
        int256 size = long ? F.toInt(amount) : -F.toInt(amount);
        uint256 entry = amount * 100 / 1e18;
        uint256 maintenance = Math.mulDiv(entry, 1500, 10_000, Math.Rounding.Ceil);
        uint256 collateral = maintenance + uint256(seed >> 64) % 200 + 100;
        if (_twapUnhealthy(a, size, entry, collateral, maintenance, 100)) return;
        uint256 cap = Risk.sideCap(a.baseAtSeed, 1715);
        uint256 endBase = long ? a.baseAtSeed + cap : a.baseAtSeed - cap;
        uint256 limit = Math.mulDiv(Math.ceilDiv(a.k, endBase), 1e18, endBase);
        uint256 expected;
        for (uint256 p = long ? 99 : 101; long ? p >= limit : p <= limit; p = long ? p - 1 : p + 1) {
            if (_twapUnhealthy(a, size, entry, collateral, maintenance, p)) {
                expected = p;
                break;
            }
        }
        assertEq(Prices.twapPrice(a, size, entry, collateral, maintenance, 100, 1715), expected);
    }

    function _executable(Capacity.Context memory c, uint256 amount) internal pure returns (bool) {
        int256 delta = c.isLong ? F.toInt(amount) : -F.toInt(amount);
        T.Fill memory q = Curve.quoteExit(c.amm, -delta);
        if (q.quoteAmount == 0) return false;
        uint256 entry = c.entry + q.quoteAmount;
        uint256 longs = c.longs + (c.isLong ? amount : 0);
        uint256 shorts = c.shorts + (c.isLong ? 0 : amount);
        if (Math.mulDiv(Math.max(longs, shorts), q.newMark, 1e18, Math.Rounding.Ceil) > c.oiCap) return false;
        if (Math.mulDiv(c.size + amount, q.newMark, 1e18, Math.Rounding.Ceil) > 2_000e18) return false;
        uint256 worst = Risk.worstClose(c.amm, c.isLong, c.size + amount, c.config.sideCapBps);
        int256 loss = c.isLong ? F.toInt(entry) - F.toInt(worst) : F.toInt(worst) - F.toInt(entry);
        uint256 floor = (loss > 0 ? F.toUint(loss) : 0)
            + Math.mulDiv(entry, c.config.mmrBps, 10_000, Math.Rounding.Ceil)
            + Math.mulDiv(worst, c.config.takerFeeBps, 10_000, Math.Rounding.Ceil);
        uint256 margin = Math.max(
            floor,
            Risk.initialMargin(
                c.amm,
                c.isLong ? F.toInt(c.size + amount) : -F.toInt(c.size + amount),
                entry,
                c.config.maxLeverageX,
                c.config.mmrBps,
                c.config.sideCapBps
            )
        );
        uint256 beforeSkew = _skew(c.longs, c.shorts);
        uint256 fee = Fees.takerFee(q.quoteAmount, c.config.takerFeeBps, beforeSkew, _skew(longs, shorts) < beforeSkew);
        return fee <= c.free && c.collateral + F.toInt(c.free - fee) >= F.toInt(margin);
    }

    function _indexUnhealthy(int256 size, uint256 entry, uint256 collateral, uint256 maintenance, uint256 price)
        private
        pure
        returns (bool)
    {
        uint256 value = Math.mulDiv(F.abs(size), price, 1e18, size > 0 ? Math.Rounding.Floor : Math.Rounding.Ceil);
        int256 pnl = size > 0 ? F.toInt(value) - F.toInt(entry) : F.toInt(entry) - F.toInt(value);
        return F.toInt(collateral) + pnl < F.toInt(maintenance);
    }

    function _twapUnhealthy(
        T.AmmState memory a,
        int256 size,
        uint256 entry,
        uint256 collateral,
        uint256 maintenance,
        uint256 price
    ) private pure returns (bool) {
        a.baseReserve = Math.sqrt(Math.mulDiv(a.k, 1e18, price));
        a.quoteReserve = Math.ceilDiv(a.k, a.baseReserve);
        return F.toInt(collateral) + Curve.realizablePnl(a, size, entry) < F.toInt(maintenance);
    }

    function _skew(uint256 longs, uint256 shorts) private pure returns (uint256) {
        return
            longs + shorts == 0
                ? 0
                : Math.mulDiv(longs > shorts ? longs - shorts : shorts - longs, 1e18, longs + shorts);
    }
}
