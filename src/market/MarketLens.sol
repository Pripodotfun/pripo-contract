// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {FeeMath as Fees} from "../libraries/FeeMath.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {RiskMath as Risk} from "../libraries/RiskMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketState as S} from "./MarketState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Linked quote and risk calculations using the same state and arithmetic as execution.
library MarketLens {
    function quoteOpen(S.Data storage s, address user, int256 size) public view returns (S.OpenQuote memory q) {
        if (user == address(0) || size == 0 || size == type(int256).min) revert E.InvalidSize();
        T.Position memory p = s._positions[user];
        if (p.size != 0 && (p.size > 0) != (size > 0)) revert E.PositionExists();
        q.fill = Curve.quote(s._amm, size);
        q.newSize = p.size + size;
        q.newEntry = p.entryCost + q.fill.quoteAmount;
        uint256 newLongs = s.longSize + (size > 0 ? F.abs(size) : 0);
        uint256 newShorts = s.shortSize + (size < 0 ? F.abs(size) : 0);
        uint256 baseCap = Risk.sideCap(s._amm.baseAtSeed, s._config.sideCapBps);
        if (newLongs > baseCap || newShorts > baseCap) revert E.OICapExceeded(baseCap, Math.max(newLongs, newShorts));
        uint256 notional = Math.mulDiv(Math.max(newLongs, newShorts), q.fill.newMark, F.WAD, Math.Rounding.Ceil);
        uint256 cap = Engine.oiCap(s);
        if (notional > cap) revert E.OICapExceeded(cap, notional);
        uint256 userNotional = Math.mulDiv(F.abs(q.newSize), q.fill.newMark, F.WAD, Math.Rounding.Ceil);
        if (userNotional > 2_000e18) revert E.OICapExceeded(2_000e18, userNotional);
        uint256 required = Engine.initialMargin(s, q.newSize, q.newEntry);
        int256 available = s.vault.locked(user, address(this)) - Engine.fundingOwed(s, p);
        q.margin = available < F.toInt(required) ? F.toUint(F.toInt(required) - available) : 0;
        uint256 skewBefore = Engine.absoluteSkew(s.longSize, s.shortSize);
        bool reducesSkew = Engine.absoluteSkew(newLongs, newShorts) < skewBefore;
        q.fee = Fees.takerFee(q.fill.quoteAmount, s._config.takerFeeBps, skewBefore, reducesSkew);
    }

    function quoteClose(S.Data storage s, address user, uint256 fraction) public view returns (S.CloseQuote memory q) {
        T.Position memory p = s._positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) revert E.NoPosition();
        if (fraction == 0 || fraction > F.WAD) revert E.InvalidSize();
        uint256 amount = Math.mulDiv(F.abs(p.size), fraction, F.WAD);
        q.closedEntry = Curve.closedEntryCost(p.entryCost, amount, F.abs(p.size));
        q.closedSize = p.size > 0 ? F.toInt(amount) : -F.toInt(amount);
        q.fill = Curve.quoteExit(s._amm, q.closedSize);
        q.pnl = p.size > 0
            ? F.toInt(q.fill.quoteAmount) - F.toInt(q.closedEntry)
            : F.toInt(q.closedEntry) - F.toInt(q.fill.quoteAmount);
        q.fee = Fees.takerFee(q.fill.quoteAmount, s._config.takerFeeBps, 0, false);
    }

    function health(S.Data storage s, address user) public view returns (int256 healthWad, bool liquidatable) {
        T.Position memory p = s._positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return (type(int256).max, false);
        int256 equity = s.vault.locked(user, address(this)) + Engine.referencePnl(s, p) - Engine.fundingOwed(s, p);
        uint256 magnitude = Math.mulDiv(F.abs(equity), F.WAD, p.entryCost);
        healthWad = equity < 0 ? -F.toInt(magnitude) : F.toInt(magnitude);
        uint256 mmr = Engine.isDegraded(s) ? 1500 : s._config.mmrBps;
        liquidatable = equity < F.toInt(Math.mulDiv(p.entryCost, mmr, F.BPS, Math.Rounding.Ceil));
    }

    function realizablePnl(S.Data storage s, address user) public view returns (int256, int256) {
        T.Position memory p = s._positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return (0, 0);
        return (
            Curve.realizablePnl(s._amm, p.size, p.entryCost),
            Curve.realizablePnl(Engine.twapReserves(s), p.size, p.entryCost)
        );
    }
}
