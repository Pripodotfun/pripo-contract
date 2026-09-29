// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarginVault} from "../interfaces/IMarginVault.sol";
import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {FundingMath as Funding} from "../libraries/FundingMath.sol";
import {MarkTwap} from "../libraries/MarkTwap.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketState as S} from "./MarketState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Whole-book TWAP settlement. Execution is reachable only from the liquidation shortfall preflight.
library MarketSettlement {
    using MarkTwap for MarkTwap.State;

    struct Plan {
        T.SettlementQuote quote;
        address[] users;
        int256[] pnls;
        uint256[] profits;
    }

    /// @notice Hypothetical terminal valuation of the current complete book, before any caller's keeper penalty.
    function quote(S.Data storage s) public view returns (T.SettlementQuote memory) {
        return plan(s).quote;
    }

    // Only the fixed vault is read in the at-most-128-position loop; no user-controlled call targets.
    // slither-disable-next-line calls-loop
    function plan(S.Data storage s) internal view returns (Plan memory p) {
        if (s._config.status >= T.Status.Settling) revert E.MarketNotActive();
        p.users = s._accounts;
        p.pnls = new int256[](p.users.length);
        p.profits = new uint256[](p.users.length);
        T.SettlementQuote memory q = p.quote;
        q.price = s._twap.consult(300, Engine.currentBlock());
        q.positions = p.users.length;
        T.Ledger memory ledger = s.vault.ledger(address(this));
        q.clearing = ledger.clearing;
        int256 pool = ledger.fundingPool;
        T.FundingState memory funding = Engine.previewFunding(s);
        for (uint256 i; i < p.users.length; ++i) {
            T.Position memory pos = s._positions[p.users[i]];
            int256 margin = s.vault.locked(p.users[i], address(this));
            int256 owed;
            // The returned snapshot is not needed in this read-only whole-book simulation.
            // slither-disable-next-line unused-return
            (funding, owed,) = Funding.settle(funding, pos.size, pos.lastFundingIndex);
            pool += owed;
            uint256 value =
                Math.mulDiv(F.abs(pos.size), q.price, F.WAD, pos.size > 0 ? Math.Rounding.Floor : Math.Rounding.Ceil);
            int256 pnl =
                pos.size > 0 ? F.toInt(value) - F.toInt(pos.entryCost) : F.toInt(pos.entryCost) - F.toInt(value);
            p.pnls[i] = pnl;
            q.clearing -= pnl;
            int256 equity = margin + pnl - owed;
            if (equity < 0) q.debt += F.abs(equity);
            // Only new positive settlement profit is haircuttable. Already-realized collateral is principal here.
            int256 gain = pnl - owed;
            if (equity > 0 && gain > 0) {
                p.profits[i] = Math.min(F.toUint(equity), F.toUint(gain));
                q.profits += p.profits[i];
            }
            if (margin > 0 && gain < 0) q.losingCollateral += Math.min(F.toUint(margin), F.abs(gain));
        }
        // Every position is settled at the checkpoint; pending obligations are now zero.
        if (Funding.pending(funding, s.longSize, s.shortSize) != 0 || pool < 0) revert E.AccountingInvariant();
        q.fundingSurplus = Funding.surplus(funding, pool, s.longSize, s.shortSize) / F.WAD;
        int256 net = F.toInt(q.debt) - q.clearing - F.toInt(ledger.insurance + q.fundingSurplus);
        uint256 gap = net > 0 ? F.toUint(net) : 0;
        q.haircut = Math.min(gap, q.profits);
        q.capitalRequired = gap - q.haircut;
        p.quote = q;
    }

    // The market guard spans the whole transition. The vault's custody methods do not transfer tokens or callback.
    // At most 128 accounts; all loop calls target the fixed vault. Full-book gas is regression tested.
    // slither-disable-next-line reentrancy-events,reentrancy-no-eth,calls-loop
    function execute(S.Data storage s, address liquidatedUser) public {
        Plan memory p = plan(s);
        T.SettlementQuote memory q = p.quote;
        Engine.setStatus(s, T.Status.Settling);
        emit IMarketCore.ForcedSettlement(address(this), liquidatedUser, q.price);
        uint256 allocated = 0;
        uint256 cumulative = 0;
        for (uint256 i; i < p.users.length; ++i) {
            address user = p.users[i];
            // Checkpoint all positions before removing their funding weights. No funding accrues during this loop.
            // slither-disable-next-line unused-return
            Engine.settleFunding(s, user);
            s.vault.settlePnl(user, p.pnls[i]);
            // Prefix rounding allocates exactly the haircut, independent of caller-supplied account order.
            cumulative += p.profits[i];
            uint256 next = q.profits == 0 ? 0 : Math.mulDiv(q.haircut, cumulative, q.profits);
            uint256 haircut = next - allocated;
            allocated = next;
            if (haircut != 0) s.vault.settlePnl(user, -F.toInt(haircut));
            Engine.resize(s, s._positions[user].size, 0);
            delete s._positions[user];
            delete s._accountIndex[user];
        }
        delete s._accounts;
        uint256 surplus;
        // The vault applies the transfer; the duplicate resulting pool is deliberately discarded.
        // slither-disable-next-line unused-return
        (s._funding,, surplus) = Funding.sweep(s._funding, s.vault.ledger(address(this)).fundingPool, 0, 0);
        if (surplus != q.fundingSurplus || allocated != q.haircut) revert E.AccountingInvariant();
        s.vault.sweepFunding(surplus);
        emit IMarketCore.FundingSurplusSwept(address(this), surplus);
        s._amm = Curve.seed(q.price, s._amm.curveBase);
        s._twap.write(Curve.mark(s._amm), Engine.currentBlock());
        s.settlementPrice = q.price;
        s.settlementHaircut = q.haircut;
        s.settlementProfits = q.profits;
        Engine.setStatus(s, T.Status.Settled);
        // The vault emits exact funding sources and residual deficit; no separate user credit is created here.
        // slither-disable-next-line unused-return
        s.vault.finalizeSettlement(p.users);
        for (uint256 i; i < p.users.length; ++i) {
            uint256 amount = F.toUint(s.vault.locked(p.users[i], address(this)));
            if (amount != 0) s.vault.release(p.users[i], amount);
        }
        emit IMarginVault.TerminalCoverage(address(this), 1, q.losingCollateral);
        emit IMarginVault.TerminalCoverage(address(this), 2, q.haircut);
        emit IMarketCore.SettlementHaircut(address(this), q.profits, q.haircut);
        uint16 bps =
            q.profits == 0 ? 0 : SafeCast.toUint16(Math.mulDiv(q.haircut, F.BPS, q.profits, Math.Rounding.Ceil));
        emit IMarketCore.MarketSettled(address(this), q.price, bps);
    }
}
