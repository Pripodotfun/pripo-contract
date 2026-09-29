// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {LiquidationMath as L} from "../libraries/LiquidationMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketAdl as Adl} from "./MarketAdl.sol";
import {MarketLens as Lens} from "./MarketLens.sol";
import {MarketState as S} from "./MarketState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Preflight curve coverage, then pair off-curve or settle the complete book before any winner payout.
library MarketLiquidation {
    // The market entry point holds nonReentrant across the oracle update and every vault/controller call.
    // slither-disable-next-line reentrancy-events
    function liquidate(
        S.Data storage s,
        address user,
        bytes memory update,
        uint256 value,
        address[] memory candidates,
        bool automatic
    ) public {
        if (s._positions[user].size == 0) revert E.NoPosition();
        Engine.touch(s);
        bool degraded = Engine.isDegraded(s);
        if (s.externalIndex && !degraded) {
            Engine.refreshPrice(s, update, value);
        } else if (value != 0) {
            revert E.UnexpectedValue();
        }
        // Effects settle before health; the returned debit is not part of the liquidation event.
        // slither-disable-next-line unused-return
        Engine.settleFunding(s, user);
        (int256 health, bool unhealthy) = Lens.health(s, user);
        if (!unhealthy) revert E.NotLiquidatable(health);

        int256 originalSize = s._positions[user].size;
        uint256 referencePrice = s.externalIndex && !degraded ? s._index : Engine.twapPrice(s);
        uint256 fraction = L.fraction(F.abs(originalSize), referencePrice, s.externalIndex, degraded);
        S.CloseQuote memory q = Lens.quoteClose(s, user, fraction);
        // A normal partial must leave maintenance equity after its penalty. Degraded mode caps each call at half.
        if (q.closedSize != originalSize && !degraded && _unhealthyAfterPenalty(s, user, q)) {
            q = Lens.quoteClose(s, user, F.WAD);
        }
        uint256 penalty =
            s.vault.chargeLiquidationPenalty(user, msg.sender, L.penalty(q.fill.quoteAmount, s._config.liqPenaltyBps));
        int256 equity = s.vault.locked(user, address(this)) + q.pnl;
        (uint256 insurance, uint256 backstop) = s.vault.liveCoverage(address(this));
        if (equity < 0 && F.abs(equity) > insurance + backstop) {
            (bool terminal, uint256 quote, uint256 covered) = Adl.resolve(s, user, q.closedSize, candidates, automatic);
            uint256 pairedAverage = terminal
                ? s.settlementPrice
                : Math.mulDiv(
                    quote, F.WAD, F.abs(q.closedSize), q.closedSize < 0 ? Math.Rounding.Ceil : Math.Rounding.Floor
                );
            emit IMarketCore.Liquidated(
                address(this),
                user,
                msg.sender,
                terminal ? originalSize : q.closedSize,
                pairedAverage,
                penalty,
                F.toInt(terminal ? s.vault.deficit(address(this)) : covered)
            );
            return;
        }
        Engine.applyClose(s, user, q);
        uint256 debt = Engine.coverDebt(s, user);
        if (s._positions[user].size == 0) {
            s.vault.release(user, F.toUint(s.vault.locked(user, address(this))));
            delete s._positions[user];
        }
        uint256 average = Math.mulDiv(
            q.fill.quoteAmount, F.WAD, F.abs(q.closedSize), q.closedSize < 0 ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        emit IMarketCore.Liquidated(address(this), user, msg.sender, q.closedSize, average, penalty, F.toInt(debt));
    }

    function _unhealthyAfterPenalty(S.Data storage s, address user, S.CloseQuote memory q) private view returns (bool) {
        T.Position memory p = s._positions[user];
        int256 collateral = s.vault.locked(user, address(this));
        p.size -= q.closedSize;
        p.entryCost -= q.closedEntry;
        uint256 nominal = L.penalty(q.fill.quoteAmount, s._config.liqPenaltyBps);
        uint256 charged = collateral > 0 ? Math.min(nominal, F.toUint(collateral)) : 0;
        int256 equity = collateral + q.pnl - F.toInt(charged) + Engine.referencePnl(s, p);
        return equity < F.toInt(Math.mulDiv(p.entryCost, s._config.mmrBps, F.BPS, Math.Rounding.Ceil));
    }
}
