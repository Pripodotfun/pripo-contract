// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {FeeMath as Fees} from "../libraries/FeeMath.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {LiquidationPriceMath as Prices} from "../libraries/LiquidationPriceMath.sol";
import {OpenCapacityMath as OpenCapacity} from "../libraries/OpenCapacityMath.sol";
import {RiskMath as Risk} from "../libraries/RiskMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketState as S} from "./MarketState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Linked quote and risk calculations using the same state and arithmetic as execution.
library MarketLens {
    function liquidationPriceInfo(S.Data storage s, address user)
        public
        view
        returns (uint256 price, T.LiquidationReference referenceKind, T.LiquidationPriceReason reason)
    {
        T.Position memory p = s._positions[user];
        if (p.size == 0) return (0, T.LiquidationReference.None, T.LiquidationPriceReason.NoPosition);
        if (s._pendingAdl[user].active) return (0, T.LiquidationReference.None, T.LiquidationPriceReason.PendingAdl);
        if (s._config.status >= T.Status.Settling) {
            return (0, T.LiquidationReference.None, T.LiquidationPriceReason.Inactive);
        }
        if (Engine.fundingBinding(s) == user) {
            return (0, T.LiquidationReference.None, T.LiquidationPriceReason.FundingCapacity);
        }
        int256 collateral = s.vault.locked(user, address(this)) - Engine.fundingOwed(s, p);
        if (collateral < 0) return (0, T.LiquidationReference.None, T.LiquidationPriceReason.NegativeCollateral);
        bool degraded = Engine.isDegraded(s);
        uint256 maintenance = Math.mulDiv(p.entryCost, degraded ? 1500 : s._config.mmrBps, F.BPS, Math.Rounding.Ceil);
        referenceKind = s.externalIndex && !degraded ? T.LiquidationReference.Index : T.LiquidationReference.Twap;
        int256 twapEquity = collateral + Curve.realizablePnl(Engine.twapReserves(s), p.size, p.entryCost);
        if (twapEquity < F.toInt(maintenance)) {
            return (0, referenceKind, T.LiquidationPriceReason.TwapAlreadyLiquidatable);
        }
        price = referenceKind == T.LiquidationReference.Index
            ? Prices.indexPrice(p.size, p.entryCost, F.toUint(collateral), maintenance)
            : Prices.twapPrice(
                s._amm,
                p.size,
                p.entryCost,
                F.toUint(collateral),
                maintenance,
                Engine.twapPrice(s),
                s._config.sideCapBps
            );
        reason = price == 0 ? T.LiquidationPriceReason.NoCrossing : T.LiquidationPriceReason.Threshold;
    }

    function maxOpenable(S.Data storage s, address user, bool isLong) public view returns (int256) {
        if (user == address(0) || s._config.status != T.Status.Active || s.guardianPaused || s.pendingAdlCount != 0) {
            return 0;
        }
        T.Position memory p = s._positions[user];
        if (p.size != 0 && (p.size > 0) != isLong) return 0;
        if (p.size == 0 && s._positionCount >= s._config.maxPositionsPerMarket) return 0;
        try s.vault.requireOpenAllowed(address(this)) {}
        catch {
            return 0;
        }
        OpenCapacity.Context memory c = OpenCapacity.Context(
            s._amm,
            s._config,
            s.longSize,
            s.shortSize,
            F.abs(p.size),
            p.entryCost,
            s.vault.locked(user, address(this)) - Engine.fundingOwed(s, p),
            s.vault.freeBalance(user),
            Engine.oiCap(s),
            isLong
        );
        uint256 amount = OpenCapacity.maximum(c);
        return isLong ? F.toInt(amount) : -F.toInt(amount);
    }

    function quoteOpen(S.Data storage s, address user, int256 size) public view returns (S.OpenQuote memory q) {
        if (s._config.status >= T.Status.Settling) revert E.MarketNotActive();
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

    function quoteMarginOpen(S.Data storage s, address user, bool isLong, uint256 margin, uint16 leverage)
        public
        view
        returns (T.MarginOpenQuote memory result, S.OpenQuote memory q)
    {
        if (margin == 0) revert E.ZeroAmount();
        if (leverage == 0 || leverage > s._config.maxLeverageX) revert E.InvalidLeverage(leverage);
        if (s._config.status != T.Status.Active || s.guardianPaused || s.pendingAdlCount != 0) {
            revert E.MarketNotActive();
        }
        if (s._positions[user].size == 0 && s._positionCount >= s._config.maxPositionsPerMarket) {
            revert E.PositionLimit(s._config.maxPositionsPerMarket);
        }
        s.vault.requireOpenAllowed(address(this));
        if (margin > type(uint256).max / leverage) revert E.MathOverflow();
        int256 size = Curve.sizeForNotional(s._amm, isLong, margin * leverage);
        q = quoteOpen(s, user, size);
        if (margin < q.margin) revert E.InsufficientMargin(margin, q.margin);
        uint256 free = s.vault.freeBalance(user);
        if (margin > free || q.fee > free - margin) revert E.InsufficientMargin(free, margin + q.fee);
        int256 collateral = s.vault.locked(user, address(this)) - Engine.fundingOwed(s, s._positions[user]);
        result = T.MarginOpenQuote(
            size,
            q.fill.quoteAmount,
            q.fill.avgPrice,
            q.fee,
            q.margin,
            q.fill.newMark,
            F.toUint(collateral + F.toInt(margin)),
            q.newEntry
        );
        q.margin = margin;
    }

    function quoteClose(S.Data storage s, address user, uint256 fraction) public view returns (S.CloseQuote memory q) {
        if (s._pendingAdl[user].active) revert E.AdlAlreadyPending();
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
        int256 collateral = s.vault.locked(user, address(this)) - Engine.fundingOwed(s, p);
        int256 equity = collateral + Engine.referencePnl(s, p);
        uint256 magnitude =
            p.entryCost == 0 ? uint256(type(int256).max) : Math.mulDiv(F.abs(equity), F.WAD, p.entryCost);
        healthWad = equity < 0 ? -F.toInt(magnitude) : F.toInt(magnitude);
        uint256 mmr = Engine.isDegraded(s) ? 1500 : s._config.mmrBps;
        liquidatable = !p.adlPending
            && (Engine.fundingBinding(s) == user
                || collateral < 0
                || equity < F.toInt(Math.mulDiv(p.entryCost, mmr, F.BPS, Math.Rounding.Ceil)));
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
