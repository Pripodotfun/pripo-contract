// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {FixedPointMath as F} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library RiskMath {
    /// @notice Exact floor(10_000 * phi(leverage)), without floating point or approximate square roots.
    function sideCapBps(uint16 leverage) internal pure returns (uint16) {
        if (leverage < 2) revert E.InvalidLeverage(leverage);
        uint256 lo = 0;
        uint256 hi = F.BPS;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            // mid <= phi*BPS iff lambda*(BPS-mid)^2 >= (lambda-1)*(BPS+mid)^2.
            uint256 left = uint256(leverage) * (F.BPS - mid) * (F.BPS - mid);
            uint256 right = uint256(leverage - 1) * (F.BPS + mid) * (F.BPS + mid);
            if (left >= right) lo = mid;
            else hi = mid - 1;
        }
        // The search interval is [0, 10_000], which fits uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(lo);
    }

    function sideCap(uint256 baseAtSeed, uint16 capBps) internal pure returns (uint256) {
        if (capBps == 0 || capBps >= F.BPS) revert E.InvalidBps(capBps);
        return Math.mulDiv(baseAtSeed, capBps, F.BPS);
    }

    function minimumDepth(uint256 seedBondWad, uint16 oiMultiplier, uint16 capBps) internal pure returns (uint256) {
        if (seedBondWad == 0 || oiMultiplier == 0) revert E.ZeroAmount();
        if (capBps == 0 || capBps >= F.BPS) revert E.InvalidBps(capBps);
        return Math.mulDiv(seedBondWad, uint256(oiMultiplier) * F.BPS, capBps, Math.Rounding.Ceil);
    }

    /// @notice Conservative worst-case long proceeds or short buyback cost, including the position in reserves.
    function worstClose(T.AmmState memory a, bool isLong, uint256 size, uint16 capBps) internal pure returns (uint256) {
        if (a.k == 0 || a.baseAtSeed == 0) revert E.InvalidReserves();
        uint256 cap = sideCap(a.baseAtSeed, capBps);
        if (size == 0 || size > cap) revert E.InvalidSize();
        if (isLong) {
            uint256 afterBase = a.baseAtSeed + cap;
            uint256 beforeQuote = a.k / (afterBase - size);
            uint256 afterQuote = Math.ceilDiv(a.k, afterBase);
            return beforeQuote > afterQuote ? beforeQuote - afterQuote : 0;
        }
        uint256 shortAfterBase = a.baseAtSeed - cap;
        return Math.ceilDiv(a.k, shortAfterBase) - a.k / (shortAfterBase + size);
    }

    /// @notice Phase 1 requires the full impact minimum. Fees are paid separately.
    function initialMargin(
        T.AmmState memory a,
        int256 size,
        uint256 entryCost,
        uint16 leverage,
        uint16 mmrBps,
        uint16 capBps
    ) internal pure returns (uint256) {
        if (leverage < 2) revert E.InvalidLeverage(leverage);
        if (mmrBps >= F.BPS) revert E.InvalidBps(mmrBps);
        if (entryCost == 0) revert E.ZeroAmount();
        uint256 worst = worstClose(a, size > 0, F.abs(size), capBps);
        int256 loss = size > 0 ? F.toInt(entryCost) - F.toInt(worst) : F.toInt(worst) - F.toInt(entryCost);
        uint256 buffer = Math.mulDiv(entryCost, mmrBps, F.BPS, Math.Rounding.Ceil);
        int256 impact = loss + F.toInt(buffer);
        uint256 leverageMinimum = Math.ceilDiv(entryCost, leverage);
        return impact <= 0 ? leverageMinimum : Math.max(leverageMinimum, F.toUint(impact));
    }
}
