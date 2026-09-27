// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {FixedPointMath as F} from "./FixedPointMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Constant-product virtual fills. Curve entry costs exclude fees and skew premiums.
library CurveMath {
    function seed(uint256 price, uint256 depth) internal pure returns (T.AmmState memory a) {
        if (price == 0 || depth == 0) revert E.ZeroAmount();
        uint256 base = Math.mulDiv(depth, F.WAD, price);
        if (base == 0) revert E.InvalidReserves();
        if (base > type(uint256).max / depth) revert E.MathOverflow();
        a = T.AmmState(base, depth, base * depth, base, depth, 0);
    }

    function validate(T.AmmState memory a) internal pure {
        if (a.baseReserve == 0 || a.quoteReserve == 0 || a.k == 0) revert E.InvalidReserves();
        if (a.quoteReserve != Math.ceilDiv(a.k, a.baseReserve)) revert E.InvalidReserves();
    }

    function mark(T.AmmState memory a) internal pure returns (uint256) {
        validate(a);
        return Math.mulDiv(a.quoteReserve, F.WAD, a.baseReserve);
    }

    /// @param size Positive buys base, negative sells base. Zero and zero-quote trades revert.
    /// @dev Every endpoint uses ceil(k / B). Buys pay up and sells receive down without changing k.
    function quote(T.AmmState memory a, int256 size) internal pure returns (T.Fill memory fill) {
        validate(a);
        if (size == 0) revert E.InvalidSize();
        uint256 amount = F.abs(size);
        bool isBuy = size > 0;
        if (isBuy) {
            if (amount >= a.baseReserve) revert E.ReserveExhausted();
            fill.baseReserve = a.baseReserve - amount;
        } else {
            if (amount > type(uint256).max - a.baseReserve) revert E.MathOverflow();
            fill.baseReserve = a.baseReserve + amount;
        }
        fill.quoteReserve = Math.ceilDiv(a.k, fill.baseReserve);
        fill.quoteAmount = isBuy ? fill.quoteReserve - a.quoteReserve : a.quoteReserve - fill.quoteReserve;
        if (fill.quoteAmount == 0) revert E.ZeroQuote();
        fill.avgPrice = Math.mulDiv(fill.quoteAmount, F.WAD, amount, isBuy ? Math.Rounding.Ceil : Math.Rounding.Floor);
        fill.newMark = Math.mulDiv(fill.quoteReserve, F.WAD, fill.baseReserve);
    }

    /// @notice Exact close-alone curve PnL, using quote amounts rather than a rounded average price.
    function realizablePnl(T.AmmState memory a, int256 size, uint256 entryCost) internal pure returns (int256) {
        if (size == type(int256).min) revert E.MathOverflow();
        T.Fill memory fill = quote(a, -size);
        return
            size > 0 ? F.toInt(fill.quoteAmount) - F.toInt(entryCost) : F.toInt(entryCost) - F.toInt(fill.quoteAmount);
    }

    /// @notice Remove the closed portion of entry cost; a full close removes the final remainder.
    function closedEntryCost(uint256 entryCost, uint256 closedSize, uint256 positionSize)
        internal
        pure
        returns (uint256)
    {
        if (closedSize == 0 || closedSize > positionSize) revert E.InvalidSize();
        return closedSize == positionSize ? entryCost : Math.mulDiv(entryCost, closedSize, positionSize);
    }

    function clearing(T.AmmState memory a) internal pure returns (int256) {
        return F.toInt(a.quoteReserve) - F.toInt(a.curveBase) - a.entryCostNet;
    }
}
