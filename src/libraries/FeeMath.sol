// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {FixedPointMath as F} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library FeeMath {
    /// @notice Taker fee with the Phase 1 discount for an open that reduces absolute skew.
    function takerFee(uint256 notional, uint16 takerBps, uint256 absSkewBefore, bool reducesSkew)
        internal
        pure
        returns (uint256)
    {
        if (takerBps > F.BPS) revert E.InvalidBps(takerBps);
        if (absSkewBefore > F.WAD) revert E.InvalidSize();
        uint256 factor = reducesSkew ? F.WAD - absSkewBefore / 2 : F.WAD;
        return Math.mulDiv(notional, uint256(takerBps) * factor, F.BPS * F.WAD, Math.Rounding.Ceil);
    }

    /// @notice Fee splits floor individual shares; protocol receives the remainder and unused referral share.
    function split(uint256 total, uint16 creatorBps, uint16 insuranceBps, uint16 referralBps, bool hasReferrer)
        internal
        pure
        returns (T.FeeBreakdown memory f)
    {
        uint256 shares = uint256(creatorBps) + insuranceBps + referralBps;
        if (shares > F.BPS) revert E.InvalidBps(shares);
        f.total = total;
        f.creator = Math.mulDiv(total, creatorBps, F.BPS);
        f.insurance = Math.mulDiv(total, insuranceBps, F.BPS);
        f.referral = hasReferrer ? Math.mulDiv(total, referralBps, F.BPS) : 0;
        f.protocol = total - f.creator - f.insurance - f.referral;
    }
}
