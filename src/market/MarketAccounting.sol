// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {FeeMath as Fees} from "../libraries/FeeMath.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../libraries/FundingMath.sol";
import {MarkTwap} from "../libraries/MarkTwap.sol";
import {RiskMath as Risk} from "../libraries/RiskMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketFundingCapacity as Capacity} from "./MarketFundingCapacity.sol";
import {MarketState as S} from "./MarketState.sol";
import {PositionBook as Book} from "./PositionBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Shared linked accounting transitions; external callers hold the market reentrancy guard.
library MarketAccounting {
    using MarkTwap for MarkTwap.State;

    function referencePnl(S.Data storage s, T.Position memory p) public view returns (int256 pnl) {
        pnl = Curve.realizablePnl(twapReserves(s), p.size, p.entryCost);
        if (s.externalIndex && !isDegraded(s)) {
            uint256 quote =
                Math.mulDiv(F.abs(p.size), s._index, F.WAD, p.size > 0 ? Math.Rounding.Floor : Math.Rounding.Ceil);
            int256 indexPnl = p.size > 0 ? F.toInt(quote) - F.toInt(p.entryCost) : F.toInt(p.entryCost) - F.toInt(quote);
            if (indexPnl < pnl) pnl = indexPnl;
        }
    }

    function twapReserves(S.Data storage s) internal view returns (T.AmmState memory a) {
        a = s._amm;
        uint256 twap = twapPrice(s);
        a.baseReserve = Math.sqrt(Math.mulDiv(a.k, F.WAD, twap));
        a.quoteReserve = Math.ceilDiv(a.k, a.baseReserve);
    }

    function twapPrice(S.Data storage s) internal view returns (uint256) {
        return s._twap.consult(isDegraded(s) ? 600 : 300, currentBlock());
    }

    function cachedRate(S.Data storage s) internal view returns (int256) {
        return s.externalIndex
            ? Funding.oracleRate(Curve.mark(s._amm), s._index, 12_000, s._config.fundingCapPerBlock)
            : Funding.skewRate(s.longSize, s.shortSize, 0.05e18, 12_000, s._config.fundingCapPerBlock);
    }

    function previewFunding(S.Data storage s) public view returns (T.FundingState memory f) {
        (f,) = _previewFunding(s);
    }

    function fundingBinding(S.Data storage s) public view returns (address binding) {
        (, binding) = _previewFunding(s);
    }

    function _previewFunding(S.Data storage s) private view returns (T.FundingState memory f, address binding) {
        f = s._funding;
        binding = s.fundingBinding;
        if (s._config.status >= T.Status.Settling) return (f, binding);
        uint64 current = currentBlock();
        uint64 end = current;
        if (s.externalIndex) {
            uint64 cutoff = SafeCast.toUint64(uint256(s._indexBlock) + s._config.degradeAfterBlocks + 1);
            if (end > cutoff) end = cutoff;
        }
        if (end > f.lastBlock && s._config.status != T.Status.Degraded && s.pendingAdlCount == 0) {
            uint256 referencePrice = s.externalIndex ? s._index : s._twap.consult(300, current);
            (f, binding) = Capacity.preview(s, f, cachedRate(s), referencePrice, end);
        }
        f.lastBlock = current;
    }

    function touch(S.Data storage s) public {
        if (s._config.status >= T.Status.Settling) revert E.MarketNotActive();
        int256 rate = isDegraded(s) || s.pendingAdlCount != 0 ? int256(0) : cachedRate(s);
        address binding;
        (s._funding, binding) = _previewFunding(s);
        Capacity.latch(s, binding);
        if (binding != address(0)) rate = 0;
        // The equality discriminates an enum; oracle age uses an ordered comparison.
        // slither-disable-next-line incorrect-equality
        if (isDegraded(s) && s._config.status == T.Status.Active) setStatus(s, T.Status.Degraded);
        s._twap.write(Curve.mark(s._amm), currentBlock());
        emit IMarketCore.FundingAccrued(
            address(this), rate, s._funding.longIndex, s._funding.shortIndex, currentBlock()
        );
    }

    function settleFunding(S.Data storage s, address user) public returns (int256 owed) {
        T.Position storage p = s._positions[user];
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return 0;
        (s._funding, owed, p.lastFundingIndex) = Funding.settle(s._funding, p.size, p.lastFundingIndex);
        if (owed > 0) Capacity.checkDebit(s, user, owed);
        if (owed != 0) s.vault.settleFunding(user, owed);
    }

    function fundingOwed(S.Data storage s, T.Position memory p) internal view returns (int256 owed) {
        // Zero is the exact empty-position sentinel.
        // slither-disable-next-line incorrect-equality
        if (p.size == 0) return 0;
        // Read-only simulation needs only the debit; it deliberately discards the simulated state and snapshot.
        // slither-disable-next-line unused-return
        (, owed,) = Funding.settle(previewFunding(s), p.size, p.lastFundingIndex);
    }

    function resize(S.Data storage s, int256 oldSize, int256 newSize) internal {
        s._funding = Funding.changeSize(s._funding, oldSize, newSize);
        if (oldSize > 0) s.longSize -= F.abs(oldSize);
        if (oldSize < 0) s.shortSize -= F.abs(oldSize);
        if (newSize > 0) s.longSize += F.abs(newSize);
        if (newSize < 0) s.shortSize += F.abs(newSize);
    }

    function applyFill(S.Data storage s, T.Fill memory fill) internal {
        s.lastTradeTimestamp = uint64(block.timestamp);
        s._amm.baseReserve = fill.baseReserve;
        s._amm.quoteReserve = fill.quoteReserve;
        s._twap.write(fill.newMark, currentBlock());
    }

    function applyClose(S.Data storage s, address user, S.CloseQuote memory q) internal {
        T.Position storage p = s._positions[user];
        int256 remaining = p.size - q.closedSize;
        resize(s, p.size, remaining);
        p.size = remaining;
        if (remaining == 0) Book.remove(s, user);
        p.entryCost -= q.closedEntry;
        s._amm.entryCostNet -= q.closedSize > 0 ? F.toInt(q.closedEntry) : -F.toInt(q.closedEntry);
        applyFill(s, q.fill);
        s.vault.settlePnl(user, q.pnl);
    }

    /// @dev Voluntary full closes require complete live coverage; forced liquidation has its separate ADL/terminal path.
    // The market holds its guard; the bound backstop controller makes only static reads before updating its budget.
    // slither-disable-next-line reentrancy-events
    function coverDebt(S.Data storage s, address user) internal returns (uint256 debt) {
        (uint256 insurance, uint256 backstop, uint256 remaining) = s.vault.coverBadDebt(user);
        if (remaining != 0) revert E.UncoveredBadDebt(remaining);
        debt = insurance + backstop;
        if (insurance != 0) emit IMarketCore.BadDebt(address(this), user, insurance, 0);
        if (backstop != 0) emit IMarketCore.BadDebt(address(this), user, backstop, 1);
    }

    // The pinned vault chargeFee makes only ledger writes; the market holds its guard through this call.
    // slither-disable-next-line reentrancy-events
    function chargeFee(S.Data storage s, address user, uint256 fee, bool fromLocked) internal {
        T.FeeBreakdown memory split = Fees.split(
            fee,
            s._config.creatorShareBps,
            s._config.insuranceShareBps,
            s._config.referralShareBps,
            s.vault.referrerOf(user) != address(0)
        );
        s.vault.chargeFee(user, split, fromLocked);
        emit IMarketCore.FeesAccrued(address(this), split.protocol, split.creator, split.insurance);
    }

    // All callers hold nonReentrant, including initialization. Cache writes follow successful adapter validation.
    // slither-disable-next-line reentrancy-benign
    function refreshPrice(S.Data storage s, bytes memory update, uint256 value) public {
        if (!s.externalIndex) {
            if (value != 0) revert E.UnexpectedValue();
            return;
        }
        S.Observation memory o = readSource(s, s._config.priceSource, update, value);
        if (!fresh(s, o) && s._config.secondarySource != address(0)) {
            o = readSource(s, s._config.secondarySource, "", 0);
        }
        // Reject zero price explicitly; freshness uses inequalities.
        // slither-disable-next-line incorrect-equality
        if (o.price == 0 || o.price > 1e28 || !o.isExternal || o.updatedBlock > block.number) revert E.InvalidOracle();
        if (o.confidence > 100) revert E.OracleConfidence(o.confidence);
        if (!fresh(s, o)) revert E.StaleOracle(currentBlock() - o.updatedBlock);
        s._index = o.price;
        s._indexBlock = o.updatedBlock;
    }

    // Source comes only from validated, immutable market configuration; value is the caller's supplied update fee.
    // slither-disable-next-line arbitrary-send-eth
    function readSource(S.Data storage s, address source, bytes memory update, uint256 value)
        internal
        returns (S.Observation memory o)
    {
        try IPriceSource(source).getPrice{value: value}(s.feedId, update) returns (
            uint256 p, uint64 b, uint16 c, bool ext
        ) {
            o = S.Observation(p, b, c, ext);
        } catch {
            if (value != 0) revert E.InvalidOracle();
        }
    }

    function fresh(S.Data storage s, S.Observation memory o) internal view returns (bool) {
        return o.price != 0 && o.price <= 1e28 && o.isExternal && o.confidence <= 100 && o.updatedBlock <= block.number
            && block.number - o.updatedBlock <= s._config.maxOracleAgeBlocks;
    }

    function isDegraded(S.Data storage s) internal view returns (bool) {
        // Exact enum match plus an ordered age check.
        // slither-disable-next-line incorrect-equality
        return s._config.status == T.Status.Degraded
            || (s.externalIndex && block.number > uint256(s._indexBlock) + s._config.degradeAfterBlocks);
    }

    function setStatus(S.Data storage s, T.Status next) internal {
        // Avoid duplicate enum transition events.
        // slither-disable-next-line incorrect-equality
        if (next == s._config.status) return;
        emit IMarketCore.StatusChanged(address(this), uint8(s._config.status), uint8(next), currentBlock());
        s._config.status = next;
        s._config.statusSince = currentBlock();
    }

    function initialMargin(S.Data storage s, int256 size, uint256 entry) internal view returns (uint256) {
        return Math.max(
            Risk.initialMargin(s._amm, size, entry, s._config.maxLeverageX, s._config.mmrBps, s._config.sideCapBps),
            Capacity.protectedCollateral(s, size, entry)
        );
    }

    function oiCap(S.Data storage s) internal view returns (uint256) {
        uint256 insurance = s.vault.ledger(address(this)).insurance;
        if (s.handoffEconomics) return Math.min(insurance, s.seedBond) * 50;
        return Math.min(insurance * (s.externalIndex ? 20 : 10), 25_000e18);
    }

    function validateDepth(S.Data storage s, uint256 depth) public view {
        uint256 insurance = s.vault.ledger(address(this)).insurance;
        uint256 minimumBond = s.handoffEconomics ? 1_000e18 : (s.externalIndex ? 5_000e18 : 2_000e18);
        if (insurance < minimumBond) revert E.InsufficientInsurance(insurance, minimumBond);
        if (s.handoffEconomics) insurance = Math.min(insurance, s.seedBond);
        uint16 multiplier = s.handoffEconomics ? 50 : (s.externalIndex ? 20 : 10);
        uint256 minimum = Risk.minimumDepth(insurance, multiplier, s._config.sideCapBps);
        if (depth < minimum || depth > 1e28 || s._amm.baseAtSeed > 1e28) revert E.InvalidReserves();
        uint256 coverage = Math.mulDiv(Risk.sideCap(s._amm.baseAtSeed, s._config.sideCapBps), Curve.mark(s._amm), F.WAD);
        if (coverage < insurance * multiplier) revert E.InvalidReserves();
    }

    function validateConfig(S.Data storage s, T.MarketConfig calldata c) public view {
        uint16 maximum = s.externalIndex ? 5 : 2;
        if (
            c.creator == address(0) || c.maxLeverageX < 2 || c.maxLeverageX > maximum || c.sideCapBps == 0
                || c.sideCapBps > Risk.sideCapBps(c.maxLeverageX) || c.mmrBps != (s.externalIndex ? 250 : 1500)
                || c.impactMarginBps != F.BPS || c.skewCoeff != 0 || c.takerFeeBps != 8
                || c.creatorShareBps != (s.handoffEconomics ? 2000 : 3000) || c.insuranceShareBps != 3000
                || c.referralShareBps != 1000 || c.receiveCapX != 10 || c.liqPenaltyBps != 150
                || c.maxOracleAgeBlocks == 0 || c.degradeAfterBlocks <= c.maxOracleAgeBlocks
                || c.degradedTwapBlocks != 600 || c.adlPendingWindow == 0 || c.maxPositionsPerMarket < 2
                || c.maxPositionsPerMarket > Book.MAX_POSITIONS
                || c.fundingCapPerBlock > (s.externalIndex ? uint256(0.001e18) / 12_000 : uint256(0.005e18) / 12_000)
                || (s.externalIndex && c.priceSource.code.length == 0)
                || (c.secondarySource != address(0) && c.secondarySource.code.length == 0)
        ) revert E.InvalidConfiguration();
    }

    function checkLimit(int256 size, uint256 average, uint256 limit) internal pure {
        if ((size > 0 && average > limit) || (size < 0 && average < limit)) revert E.Slippage(limit, average);
    }

    function absoluteSkew(uint256 longs, uint256 shorts) internal pure returns (uint256) {
        // Exact integer-zero guard prevents division by zero.
        // slither-disable-next-line incorrect-equality
        if (longs + shorts == 0) return 0;
        return Math.mulDiv(longs > shorts ? longs - shorts : shorts - longs, F.WAD, longs + shorts);
    }

    function currentBlock() internal view returns (uint64) {
        return SafeCast.toUint64(block.number);
    }
}
