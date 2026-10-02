// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketSettlement as Settlement} from "./MarketSettlement.sol";
import {MarketState as S} from "./MarketState.sol";
import {PositionBook as Book} from "./PositionBook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Paired closes at a shared quote per match. The curve is never traded on this path.
library MarketAdl {
    uint256 internal constant MAX_REBALANCE_CHECKS = 512;

    struct Candidate {
        address user;
        T.Position position;
        int256 margin;
        uint256 score;
        uint256 price;
        bool eligible;
    }

    struct Match {
        address user;
        int256 size;
        uint256 entry;
        uint256 quote;
        int256 margin;
        uint256 candidateIndex;
    }

    struct Plan {
        Match[] matches;
        uint256 count;
        uint256 matched;
        uint256 quote;
        uint256 entry;
        int256 margin;
        uint256 coverage;
        uint256 rebalanceChecks;
    }

    /// @dev Returns true when the whole market was settled, false after a successful paired close.
    // Market guard covers all linked execution and vault writes; the bound coverage controller has no callbacks.
    // At most 128 matches; calls target only the fixed vault. Full-book execution has a gas regression test.
    // slither-disable-next-line reentrancy-events,reentrancy-no-eth,calls-loop
    function resolve(S.Data storage s, address user, int256 closedSize, address[] memory supplied, bool automatic)
        public
        returns (bool terminal, uint256 quoteAmount, uint256 covered)
    {
        (uint256 insurance, uint256 backstop) = s.vault.liveCoverage(address(this));
        uint256 capacity = insurance + backstop;
        Candidate[] memory candidates = _candidates(s, user, closedSize, capacity);
        uint256[] memory order = _order(candidates);
        Plan memory p = _plan(s, user, closedSize, capacity, candidates, order, supplied, automatic);
        if (p.matched != F.abs(closedSize)) {
            // Caller omissions cannot force terminal settlement: inspect the entire canonical book first.
            if (!automatic) {
                Plan memory complete = _plan(s, user, closedSize, capacity, candidates, order, new address[](0), true);
                if (complete.matched == F.abs(closedSize)) revert E.IncompleteAdlCandidates();
            }
            // A rounded last fragment is a candidate-allocation problem, not proof that the book is exhausted.
            // Preserve the market if full eligible positions could supply the selected size in another allocation.
            uint256 eligibleSize = 0;
            for (uint256 i; i < candidates.length; ++i) {
                if (candidates[i].eligible) eligibleSize += F.abs(candidates[i].position.size);
            }
            if (eligibleSize >= F.abs(closedSize)) revert E.IncompleteAdlCandidates();
            Settlement.execute(s, user);
            return (true, 0, 0);
        }
        for (uint256 i; i < p.count; ++i) {
            Match memory m = p.matches[i];
            // Settle the candidate to the same checkpoint used by the plan before removing its weighted size.
            // slither-disable-next-line unused-return
            Engine.settleFunding(s, m.user);
            int256 winnerPnl = m.size > 0 ? F.toInt(m.quote) - F.toInt(m.entry) : F.toInt(m.entry) - F.toInt(m.quote);
            _closePairLeg(s, m.user, m.size, m.entry, winnerPnl);
            uint256 payout = F.toUint(m.margin + winnerPnl);
            if (payout != 0) s.vault.release(m.user, payout);
            uint256 price = Math.mulDiv(m.quote, F.WAD, F.abs(m.size));
            emit IMarketCore.AutoDeleveraged(address(this), m.user, m.size, price);
        }
        int256 pnl = closedSize > 0 ? F.toInt(p.quote) - F.toInt(p.entry) : F.toInt(p.entry) - F.toInt(p.quote);
        _closePairLeg(s, user, closedSize, p.entry, pnl);
        if (p.coverage != 0) {
            (uint256 local, uint256 global, uint256 remaining) = s.vault.coverLiquidationLoss(user, p.coverage);
            if (remaining != 0) revert E.AccountingInvariant();
            if (local != 0) emit IMarketCore.BadDebt(address(this), user, local, 0);
            if (global != 0) emit IMarketCore.BadDebt(address(this), user, global, 1);
        }
        uint256 residual = F.toUint(p.margin + pnl + F.toInt(p.coverage));
        if (residual != 0) s.vault.release(user, residual);
        if (s.vault.ledger(address(this)).clearing != Curve.clearing(s._amm)) revert E.AccountingInvariant();
        return (false, p.quote, p.coverage);
    }

    // Static collateral reads of the fixed vault, bounded by the position limit.
    // slither-disable-next-line calls-loop
    function _candidates(S.Data storage s, address user, int256 closedSize, uint256 capacity)
        private
        view
        returns (Candidate[] memory result)
    {
        T.Position memory loser = s._positions[user];
        uint256 amount = F.abs(closedSize);
        uint256 entry = Curve.closedEntryCost(loser.entryCost, amount, F.abs(loser.size));
        int256 margin = marginShare(s.vault.locked(user, address(this)), amount, F.abs(loser.size));
        int256 budget =
            closedSize > 0 ? F.toInt(entry) - margin - F.toInt(capacity) : F.toInt(entry) + margin + F.toInt(capacity);
        uint256 boundary = budget > 0
            ? Math.mulDiv(F.toUint(budget), F.WAD, amount, closedSize > 0 ? Math.Rounding.Ceil : Math.Rounding.Floor)
            : 0;
        T.AmmState memory twap = Engine.twapReserves(s);
        result = new Candidate[](s._accounts.length);
        for (uint256 i; i < result.length; ++i) {
            address account = s._accounts[i];
            if (account == address(0)) continue;
            T.Position memory pos = s._positions[account];
            if (account == user || (pos.size > 0) == (closedSize > 0)) continue;
            T.Fill memory alone = Curve.quoteExit(twap, pos.size);
            int256 realPnl = pos.size > 0
                ? F.toInt(alone.quoteAmount) - F.toInt(pos.entryCost)
                : F.toInt(pos.entryCost) - F.toInt(alone.quoteAmount);
            if (realPnl <= 0) continue;
            int256 collateral = s.vault.locked(account, address(this)) - Engine.fundingOwed(s, pos);
            uint256 score = collateral <= 0
                ? type(uint256).max
                : Math.mulDiv(F.toUint(realPnl), pos.entryCost * F.WAD, F.toUint(collateral)) / F.toUint(collateral);
            // Full-position close-alone average bounds each candidate's per-unit return. Winner receives round down
            // (long), pays round up (short); all counterparties use the same exact quote for each match.
            uint256 price = closedSize > 0 ? Math.max(boundary, alone.avgPrice) : Math.min(boundary, alone.avgPrice);
            uint256 value =
                Math.mulDiv(F.abs(pos.size), price, F.WAD, pos.size > 0 ? Math.Rounding.Floor : Math.Rounding.Ceil);
            int256 pnl =
                pos.size > 0 ? F.toInt(value) - F.toInt(pos.entryCost) : F.toInt(pos.entryCost) - F.toInt(value);
            bool eligible = pnl > 0 && collateral + pnl >= 0 && (closedSize > 0 || budget >= 0);
            result[i] = Candidate(account, pos, collateral, score, price, eligible);
        }
    }

    /// @dev Heap-sort indices in O(n log n), keeping candidate structs in their original book slots.
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
        if (a.user == address(0)) return false;
        if (b.user == address(0)) return true;
        return a.score > b.score || (a.score == b.score && a.user < b.user);
    }

    function _plan(
        S.Data storage s,
        address user,
        int256 closedSize,
        uint256 capacity,
        Candidate[] memory candidates,
        uint256[] memory order,
        address[] memory supplied,
        bool automatic
    ) private view returns (Plan memory p) {
        if (supplied.length > Book.MAX_POSITIONS) revert E.InvalidAdlCandidates();
        T.Position memory loser = s._positions[user];
        uint256 needed = F.abs(closedSize);
        p.entry = Curve.closedEntryCost(loser.entryCost, needed, F.abs(loser.size));
        p.margin = marginShare(s.vault.locked(user, address(this)), needed, F.abs(loser.size));
        p.matches = new Match[](candidates.length);
        uint256 length = automatic ? candidates.length : supplied.length;
        uint256 previous = type(uint256).max;
        uint256 seen = 0;
        for (uint256 i; i < length; ++i) {
            Candidate memory c = Candidate(address(0), T.Position(0, 0, 0, 0), 0, 0, 0, false);
            uint256 candidateIndex;
            if (automatic) {
                candidateIndex = order[candidates.length - 1 - i];
                c = candidates[candidateIndex];
            } else {
                uint256 index = s._accountIndex[supplied[i]];
                if (index == 0 || seen & (uint256(1) << (index - 1)) != 0) revert E.InvalidAdlCandidates();
                seen |= uint256(1) << (index - 1);
                candidateIndex = index - 1;
                c = candidates[candidateIndex];
                if (c.user != supplied[i] || !c.eligible || c.score > previous) revert E.InvalidAdlCandidates();
                previous = c.score;
            }
            if (!c.eligible || p.matched == needed) continue;
            uint256 amount = Math.min(needed - p.matched, F.abs(c.position.size));
            (Match memory m, bool valid) = _slice(c, amount);
            if (!valid) {
                // Earlier matches are full positions. Redistribute a boundary slice before giving up on it.
                if (_rebalance(p, candidates, candidateIndex, amount)) p.matched = needed;
                continue;
            }
            m.candidateIndex = candidateIndex;
            p.matches[p.count++] = m;
            p.matched += amount;
            p.quote += m.quote;
        }
        if (p.matched == needed) {
            int256 pnl = closedSize > 0 ? F.toInt(p.quote) - F.toInt(p.entry) : F.toInt(p.entry) - F.toInt(p.quote);
            int256 equity = p.margin + pnl;
            p.coverage = equity < 0 ? F.abs(equity) : 0;
            if (p.coverage > capacity) revert E.AccountingInvariant();
        }
    }

    /// @dev A failed greedy slice is necessarily the final partial: full candidates are already eligible.
    /// Shift only as much size as required from one earlier full match, preserving the supplied score order.
    /// The conservative minimum guarantees positive profit and nonnegative equity at every size up to full.
    /// At most 512 pair checks per plan; reaching that budget is never proof of book exhaustion.
    /// No external calls or storage writes occur here.
    function _rebalance(Plan memory p, Candidate[] memory candidates, uint256 nextIndex, uint256 remainder)
        internal
        pure
        returns (bool)
    {
        Candidate memory next = candidates[nextIndex];
        uint256 nextMinimum = minimumSlice(next);
        uint256 nextSize = F.abs(next.position.size);
        for (uint256 i = p.count; i != 0; --i) {
            if (p.rebalanceChecks == MAX_REBALANCE_CHECKS) return false;
            ++p.rebalanceChecks;
            Match memory previous = p.matches[i - 1];
            Candidate memory prior = candidates[previous.candidateIndex];
            uint256 combined = F.abs(previous.size) + remainder;
            uint256 nextAmount = Math.max(remainder, nextMinimum);
            if (nextAmount <= nextSize && nextAmount < combined) {
                // The earlier slice may be valid below its sufficient bound, including with zero full equity.
                uint256 priorAmount = combined - nextAmount;
                (uint256 entry, uint256 quote, int256 margin, bool priorValid) = _sliceValues(prior, priorAmount);
                if (priorValid) {
                    (Match memory enlarged, bool nextValid) = _slice(next, nextAmount);
                    if (!nextValid) revert E.AccountingInvariant();
                    enlarged.candidateIndex = nextIndex;
                    p.quote = p.quote - previous.quote + quote + enlarged.quote;
                    p.matches[i - 1] = Match(
                        prior.user,
                        prior.position.size > 0 ? F.toInt(priorAmount) : -F.toInt(priorAmount),
                        entry,
                        quote,
                        margin,
                        previous.candidateIndex
                    );
                    p.matches[p.count++] = enlarged;
                    return true;
                }
            }
            // A candidate may also replace a whole earlier match. Validate the exact combined slice even
            // below the sufficient bound; that bound is deliberately conservative, not an eligibility rule.
            if (combined <= nextSize) {
                (Match memory replacement, bool valid) = _slice(next, combined);
                if (valid) {
                    replacement.candidateIndex = nextIndex;
                    p.quote = p.quote - previous.quote + replacement.quote;
                    for (uint256 j = i; j < p.count; ++j) {
                        p.matches[j - 1] = p.matches[j];
                    }
                    p.matches[p.count - 1] = replacement;
                    return true;
                }
            }
        }
        return false;
    }

    /// @dev With nonnegative collateral, full rounded profit P and size S give partial profit at least
    /// floor(x*P/S) for a long, or that minus one for a short. Hence x*P/S >= 1 or 2 suffices.
    /// Negative collateral needs a full close for a guaranteed releasable payout. A smaller exact slice
    /// can still qualify if its payout is zero or it absorbs all debt; the vault never releases over debt.
    function minimumSlice(Candidate memory c) internal pure returns (uint256) {
        uint256 size = F.abs(c.position.size);
        if (c.margin < 0) return size;
        (Match memory full,) = _slice(c, size);
        int256 pnl =
            c.position.size > 0 ? F.toInt(full.quote) - F.toInt(full.entry) : F.toInt(full.entry) - F.toInt(full.quote);
        if (pnl <= 0) return size;
        return Math.min(size, Math.mulDiv(size, c.position.size > 0 ? 1 : 2, F.toUint(pnl), Math.Rounding.Ceil));
    }

    function _slice(Candidate memory c, uint256 amount) private pure returns (Match memory m, bool valid) {
        (m.entry, m.quote, m.margin, valid) = _sliceValues(c, amount);
        m.user = c.user;
        m.size = c.position.size > 0 ? F.toInt(amount) : -F.toInt(amount);
    }

    /// @dev Reject unprofitable pairs before computing margin or allocating a Match in the bounded search.
    function _sliceValues(Candidate memory c, uint256 amount)
        private
        pure
        returns (uint256 entry, uint256 quote, int256 margin, bool valid)
    {
        bool long = c.position.size > 0;
        entry = Curve.closedEntryCost(c.position.entryCost, amount, F.abs(c.position.size));
        quote = Math.mulDiv(amount, c.price, F.WAD, long ? Math.Rounding.Floor : Math.Rounding.Ceil);
        if (long ? quote <= entry : entry <= quote) return (entry, quote, 0, false);
        uint256 profit = long ? quote - entry : entry - quote;
        margin = marginShare(c.margin, amount, F.abs(c.position.size));
        valid = margin >= 0 || F.abs(margin) <= profit;
        // A positive payout cannot leave negative collateral behind: MarginVault.release enforces this.
        if (valid && c.margin < margin && profit > F.abs(margin)) valid = false;
    }

    function marginShare(int256 margin, uint256 amount, uint256 size) internal pure returns (int256) {
        if (amount == size) return margin;
        uint256 magnitude =
            Math.mulDiv(F.abs(margin), amount, size, margin < 0 ? Math.Rounding.Ceil : Math.Rounding.Floor);
        return margin < 0 ? -F.toInt(magnitude) : F.toInt(magnitude);
    }

    // Called at most once per candidate, under the market guard; the fixed vault only updates balanced ledgers.
    // slither-disable-next-line calls-loop
    function _closePairLeg(S.Data storage s, address user, int256 closedSize, uint256 entry, int256 pnl) private {
        T.Position storage pos = s._positions[user];
        int256 remaining = pos.size - closedSize;
        Engine.resize(s, pos.size, remaining);
        pos.size = remaining;
        pos.entryCost -= entry;
        s._amm.entryCostNet -= closedSize > 0 ? F.toInt(entry) : -F.toInt(entry);
        s.vault.settlePnl(user, pnl);
        if (remaining == 0) {
            Book.remove(s, user);
            delete s._positions[user];
        }
    }
}
