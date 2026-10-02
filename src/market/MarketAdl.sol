// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {AdlMath as A} from "../libraries/AdlMath.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketSettlement as Settlement} from "./MarketSettlement.sol";
import {MarketState as S} from "./MarketState.sol";
import {PositionBook as Book} from "./PositionBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Reserved, value-scheduled pairing. Every caller holds the market's reentrancy guard.
library MarketAdl {
    uint256 internal constant MAX_ITERATIONS = 64;

    struct Candidate {
        address user;
        T.Position position;
        uint256 margin;
        uint256 score;
        uint256 realQuote;
        bool eligible;
    }

    struct Result {
        bool terminal;
        int256 closedSize;
        uint256 quote;
        uint256 covered;
    }

    /// @dev Funding and the single keeper penalty are checkpointed by the liquidation dispatcher before this call.
    // The market guard spans reservation and execution; the fixed vault only calls the bound backstop controller.
    // slither-disable-next-line reentrancy-events
    function start(S.Data storage s, address user, int256 closedSize, address[] memory supplied, bool automatic)
        public
        returns (Result memory)
    {
        T.AdlPending storage p = s._pendingAdl[user];
        if (p.active) revert E.AdlAlreadyPending();
        T.Position storage position = s._positions[user];
        p.S0 = F.abs(closedSize);
        p.E0 = Curve.closedEntryCost(position.entryCost, p.S0, F.abs(position.size));
        p.M0 = A.marginShare(s.vault.locked(user, address(this)), p.S0, F.abs(position.size));
        (p.reservedC, p.allowanceFromC, p.allowanceFromReserve) =
            s.vault.reserveAdl(user, s._config.maxPositionsPerMarket);
        p.budget = p.M0 + F.toInt(p.reservedC - p.allowanceFromC);
        p.isLong = closedSize > 0;
        p.V0 = p.isLong ? F.toInt(p.E0) - p.budget : F.toInt(p.E0) + p.budget;
        // An uncovered long cannot require a negative sale value; such a position has enough curve coverage.
        if (p.isLong && p.V0 < 0) revert E.AccountingInvariant();
        p.since = Engine.currentBlock();
        p.active = true;
        position.adlPending = true;
        ++s.pendingAdlCount;
        Engine.setStatus(s, T.Status.Paused);
        return _run(s, user, supplied, automatic, 0);
    }

    function continuePending(S.Data storage s, address user, address[] memory supplied) public {
        if (!s._pendingAdl[user].active) revert E.NoPendingAdl();
        Engine.touch(s);
        _run(s, user, supplied, false, 0);
    }

    function complete(S.Data storage s, address user, uint256 maxIterations) public {
        T.AdlPending storage p = s._pendingAdl[user];
        if (!p.active) revert E.NoPendingAdl();
        if (maxIterations == 0 || maxIterations > MAX_ITERATIONS) revert E.InvalidAdlIterations();
        uint256 ready = uint256(p.since) + s._config.adlPendingWindow;
        if (block.number < ready) revert E.AdlFallbackNotReady(ready);
        Engine.touch(s);
        _run(s, user, new address[](0), false, maxIterations);
    }

    /// @notice Added collateral replaces only the loss coverage that remains in this position's reservation.
    function replaceCoverage(S.Data storage s, address user, uint256 amount) public {
        T.AdlPending storage p = s._pendingAdl[user];
        if (!p.active) return;
        uint256 replaced = Math.min(amount, s.vault.adlReservation(address(this), user).lossCoverage);
        p.addedMargin += amount;
        p.replacedC += replaced;
        if (replaced != 0) s.vault.returnAdlCoverage(user, replaced);
    }

    function eligibleSize(S.Data storage s, address user) public view returns (uint256 eligible) {
        if (!s._pendingAdl[user].active) revert E.NoPendingAdl();
        (, eligible) = _book(s, s._pendingAdl[user]);
    }

    // At most 128 fixed-vault reads in preflight, 64 matches/slot visits in execution. No user call targets.
    // slither-disable-next-line calls-loop,reentrancy-events,reentrancy-no-eth
    function _run(S.Data storage s, address user, address[] memory supplied, bool automatic, uint256 iterations)
        private
        returns (Result memory result)
    {
        T.AdlPending storage p = s._pendingAdl[user];
        (Candidate[] memory candidates, uint256 eligible) = _book(s, p);
        if (!automatic && iterations == 0) _validateList(s, supplied, candidates);
        uint256 needed = p.S0 - p.matchedSize;
        // This fresh, complete scan is the only production caller of terminal execution.
        if (eligible < needed) {
            emit IMarketCore.AdlInsufficient(address(this), user, eligible, needed);
            result.terminal = true;
            result.closedSize = s._positions[user].size;
            Settlement.execute(s, user);
            return result;
        }
        uint256 beforeSize = p.matchedSize;
        uint256 beforeValue = _actualValue(p);
        uint256 beforeCoverage = p.consumedC;
        if (iterations != 0) {
            for (uint256 i; i < iterations && p.matchedSize < p.S0; ++i) {
                uint256 cursor = p.cursor;
                if (cursor == candidates.length) cursor = 0;
                p.cursor = SafeCast.toUint32(cursor + 1);
                if (candidates[cursor].eligible) _match(s, user, candidates[cursor]);
            }
        } else {
            uint256[] memory order = automatic ? _order(candidates) : new uint256[](0);
            uint256 length = automatic ? candidates.length : supplied.length;
            uint256 matched = 0;
            for (uint256 i; i < length && p.matchedSize < p.S0 && matched < MAX_ITERATIONS; ++i) {
                uint256 index = automatic ? order[length - 1 - i] : s._accountIndex[supplied[i]] - 1;
                if (!candidates[index].eligible) continue;
                _match(s, user, candidates[index]);
                ++matched;
            }
        }
        result.closedSize = p.isLong ? F.toInt(p.matchedSize - beforeSize) : -F.toInt(p.matchedSize - beforeSize);
        result.quote = _actualValue(p) - beforeValue;
        result.covered = p.consumedC > beforeCoverage ? p.consumedC - beforeCoverage : 0;
        if (p.matchedSize == p.S0) {
            _finish(s, user);
        } else {
            emit IMarketCore.AdlPending(
                address(this),
                user,
                p.S0 - p.matchedSize,
                s.vault.adlReserved(address(this), user),
                SafeCast.toUint64(uint256(p.since) + s._config.adlPendingWindow)
            );
        }
        if (s.vault.ledger(address(this)).clearing != Curve.clearing(s._amm)) revert E.AccountingInvariant();
    }

    function _actualValue(T.AdlPending storage p) private view returns (uint256) {
        uint256 value = p.V0 < 0 ? 0 : Math.mulDiv(F.toUint(p.V0), p.matchedSize, p.S0);
        return p.isLong ? value + p.relief : value - p.relief;
    }

    // Static reads of the fixed vault; slot count is bounded by the validated market cap.
    // slither-disable-next-line calls-loop
    function _book(S.Data storage s, T.AdlPending storage p)
        private
        view
        returns (Candidate[] memory candidates, uint256 eligible)
    {
        candidates = new Candidate[](s._accounts.length);
        if (p.V0 < 0) return (candidates, 0);
        T.AmmState memory twap = Engine.twapReserves(s);
        for (uint256 i; i < candidates.length; ++i) {
            address user = s._accounts[i];
            T.Position memory pos = s._positions[user];
            if (user == address(0) || pos.size == 0 || pos.adlPending || (pos.size > 0) == p.isLong) continue;
            uint256 size = F.abs(pos.size);
            if (!A.positiveAtRatio(pos.entryCost, size, F.toUint(p.V0), p.S0, pos.size > 0)) continue;
            int256 margin = s.vault.locked(user, address(this)) - Engine.fundingOwed(s, pos);
            if (margin < 0) continue;
            if (pos.size < 0 && size >= twap.baseReserve) continue;
            uint256 quote = pos.size > 0
                ? twap.quoteReserve - Math.ceilDiv(twap.k, twap.baseReserve + size)
                : Math.ceilDiv(twap.k, twap.baseReserve - size) - twap.quoteReserve;
            if (pos.size > 0 ? quote <= pos.entryCost : quote >= pos.entryCost) continue;
            uint256 profit = pos.size > 0 ? quote - pos.entryCost : pos.entryCost - quote;
            candidates[i] = Candidate({
                user: user,
                position: pos,
                margin: F.toUint(margin),
                score: A.score(profit, pos.entryCost, F.toUint(margin)),
                realQuote: quote,
                eligible: true
            });
            eligible += size;
        }
    }

    function _validateList(S.Data storage s, address[] memory supplied, Candidate[] memory candidates) private view {
        if (supplied.length > s._config.maxPositionsPerMarket) revert E.InvalidAdlCandidates();
        uint256 previous = type(uint256).max;
        uint256 seen = 0;
        for (uint256 i; i < supplied.length; ++i) {
            uint256 index = s._accountIndex[supplied[i]];
            if (index == 0 || (seen & (uint256(1) << (index - 1))) != 0) revert E.InvalidAdlCandidates();
            Candidate memory c = candidates[index - 1];
            if (!c.eligible || c.user != supplied[i] || c.score > previous) revert E.InvalidAdlCandidates();
            seen |= uint256(1) << (index - 1);
            previous = c.score;
        }
    }

    // Both legs, coverage and top-up are one guarded transition through the fixed vault, at most 64 times per call.
    // slither-disable-next-line reentrancy-events,reentrancy-no-eth,calls-loop
    function _match(S.Data storage s, address user, Candidate memory c) private {
        T.AdlPending storage p = s._pendingAdl[user];
        uint256 size = F.abs(c.position.size);
        uint256 amount = Math.min(p.S0 - p.matchedSize, size);
        uint256 afterSize = p.matchedSize + amount;
        uint256 entry = A.chunk(p.E0, p.S0, p.matchedSize, afterSize);
        uint256 scheduled = A.chunk(F.toUint(p.V0), p.S0, p.matchedSize, afterSize);
        uint256 real = Math.mulDiv(c.realQuote, amount, size, p.isLong ? Math.Rounding.Floor : Math.Rounding.Ceil);
        uint256 quote = p.isLong ? Math.max(scheduled, real) : Math.min(scheduled, real);
        p.relief += p.isLong ? quote - scheduled : scheduled - quote;
        p.matchedSize = afterSize;
        ++p.chunksMatched;
        if (p.chunksMatched > s._config.maxPositionsPerMarket) revert E.AccountingInvariant();
        uint256 winnerEntry = A.winnerEntry(c.position.entryCost, amount, size, c.position.size > 0);
        int256 profit =
            c.position.size > 0 ? F.toInt(quote) - F.toInt(winnerEntry) : F.toInt(winnerEntry) - F.toInt(quote);
        if (profit < 0) revert E.AccountingInvariant();
        int256 winnerSize = c.position.size > 0 ? F.toInt(amount) : -F.toInt(amount);
        // slither-disable-next-line unused-return
        Engine.settleFunding(s, c.user);
        _closeLeg(s, c.user, winnerSize, winnerEntry, profit);
        _closeLeg(
            s, user, -winnerSize, entry, p.isLong ? F.toInt(quote) - F.toInt(entry) : F.toInt(entry) - F.toInt(quote)
        );
        _coverage(s, user);
        uint256 payout = Math.mulDiv(c.margin, amount, size) + F.toUint(profit);
        if (payout != 0) s.vault.release(c.user, payout);
        if (profit == 0) {
            if (s.vault.payAdlRounding(user, c.user)) ++p.allowanceConsumed;
            else emit IMarketCore.AdlZeroProfit(address(this), c.user, winnerSize);
        }
        emit IMarketCore.AutoDeleveraged(address(this), c.user, user, winnerSize, quote, winnerEntry);
    }

    /// @dev Prefix coverage is provisional. Relief/replacement may restore it; only completion releases loser cash.
    // At most 64 matches; these fixed-vault ledger moves transfer no tokens and the market guard remains held.
    // slither-disable-next-line calls-loop,reentrancy-events
    function _coverage(S.Data storage s, address user) private {
        T.AdlPending storage p = s._pendingAdl[user];
        uint256 prefix = Math.mulDiv(p.reservedC - p.allowanceFromC, p.matchedSize, p.S0);
        uint256 relief = p.relief + p.replacedC;
        uint256 needed = prefix > relief ? prefix - relief : 0;
        if (needed > p.consumedC) {
            uint256 amount = needed - p.consumedC;
            s.vault.consumeAdlCoverage(user, amount);
            emit IMarketCore.BadDebt(address(this), user, amount, 2);
        }
        if (needed < p.consumedC) s.vault.restoreAdlCoverage(user, p.consumedC - needed);
        p.consumedC = needed;
    }

    // The enclosing market guard covers the fixed vault's ledger-only releases and emitted completion event.
    // slither-disable-next-line reentrancy-events
    function _finish(S.Data storage s, address user) private {
        T.AdlPending memory p = s._pendingAdl[user];
        int256 residual = p.M0 + F.toInt(p.addedMargin) - p.budget + F.toInt(p.relief + p.consumedC);
        if (residual < 0) revert E.AccountingInvariant();
        // Preserve the existing release guard even when the unselected portion has funding debt.
        if (residual != 0 && s.vault.locked(user, address(this)) >= residual) {
            s.vault.release(user, F.toUint(residual));
        }
        uint256 returned = s.vault.releaseAdlReservation(user);
        delete s._pendingAdl[user];
        s._positions[user].adlPending = false;
        --s.pendingAdlCount;
        if (s.pendingAdlCount == 0) {
            Engine.setStatus(
                s, s.guardianPaused ? T.Status.Paused : Engine.isDegraded(s) ? T.Status.Degraded : T.Status.Active
            );
        }
        emit IMarketCore.AdlCompleted(address(this), user, p.relief, returned);
    }

    // Two ledger-only legs per match, at most 64 matches; no user-controlled call target or token transfer.
    // slither-disable-next-line calls-loop
    function _closeLeg(S.Data storage s, address user, int256 size, uint256 entry, int256 pnl) private {
        T.Position storage pos = s._positions[user];
        int256 remaining = pos.size - size;
        Engine.resize(s, pos.size, remaining);
        pos.size = remaining;
        pos.entryCost -= entry;
        s._amm.entryCostNet -= size > 0 ? F.toInt(entry) : -F.toInt(entry);
        s.vault.settlePnl(user, pnl);
        if (remaining == 0) {
            Book.remove(s, user);
            delete s._positions[user];
        }
    }

    function _order(Candidate[] memory candidates) private pure returns (uint256[] memory order) {
        uint256 length = candidates.length;
        order = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            order[i] = i;
        }
        for (uint256 i = length / 2; i != 0; --i) {
            _sift(candidates, order, i - 1, length);
        }
        for (uint256 end = length; end > 1; --end) {
            (order[0], order[end - 1]) = (order[end - 1], order[0]);
            _sift(candidates, order, 0, end - 1);
        }
    }

    function _sift(Candidate[] memory candidates, uint256[] memory order, uint256 root, uint256 length) private pure {
        while (root * 2 + 1 < length) {
            uint256 child = root * 2 + 1;
            if (child + 1 < length && _before(candidates[order[child + 1]], candidates[order[child]])) ++child;
            if (!_before(candidates[order[child]], candidates[order[root]])) break;
            (order[root], order[child]) = (order[child], order[root]);
            root = child;
        }
    }

    function _before(Candidate memory a, Candidate memory b) private pure returns (bool) {
        if (!a.eligible) return false;
        if (!b.eligible) return true;
        return a.score > b.score || (a.score == b.score && a.user < b.user);
    }
}
