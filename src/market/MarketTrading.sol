// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketLens as Lens} from "./MarketLens.sol";
import {MarketState as S} from "./MarketState.sol";
import {PositionBook as Book} from "./PositionBook.sol";

/// @notice Linked trading transitions, called only while the market holds its reentrancy guard.
library MarketTrading {
    // Every caller holds nonReentrant. The oracle observes pre-trade state; vault ledger methods make no callbacks.
    // slither-disable-next-line reentrancy-eth,reentrancy-events
    function open(
        S.Data storage s,
        address user,
        int256 size,
        uint256 limitPrice,
        bytes memory update,
        bytes32[] memory proof,
        uint256 value
    ) public {
        // Enum discrimination, not a timestamp or cash-balance equality.
        // slither-disable-next-line incorrect-equality
        bool wasActive = s._config.status == T.Status.Active;
        Engine.touch(s);
        if (!wasActive || s.guardianPaused) revert E.MarketNotActive();
        Engine.refreshPrice(s, update, value);
        // A fresh observation prevents a transition caused solely by an expired cache.
        // slither-disable-next-line incorrect-equality
        if (s._config.status == T.Status.Degraded) Engine.setStatus(s, T.Status.Active);
        // Settlement effects are required; only close events need the returned debit.
        // slither-disable-next-line unused-return
        Engine.settleFunding(s, user);
        S.OpenQuote memory q = Lens.quoteOpen(s, user, size);
        Engine.checkLimit(size, q.fill.avgPrice, limitPrice);
        s.vault.checkAndConsume(user, msg.sender, q.fill.quoteAmount, false, proof);
        s.vault.lock(user, q.margin);
        Engine.chargeFee(s, user, q.fee, false);
        T.Position storage p = s._positions[user];
        int256 oldSize = p.size;
        if (oldSize == 0) Book.add(s, user);
        Engine.resize(s, oldSize, q.newSize);
        p.size = q.newSize;
        p.entryCost = q.newEntry;
        p.lastFundingIndex = size > 0 ? s._funding.longIndex : s._funding.shortIndex;
        s._amm.entryCostNet += size > 0 ? F.toInt(q.fill.quoteAmount) : -F.toInt(q.fill.quoteAmount);
        Engine.applyFill(s, q.fill);
        emit IMarketCore.PositionOpened(address(this), user, msg.sender, size, q.fill.avgPrice, q.margin, q.fee);
    }

    // All callers hold nonReentrant. Coverage calls the fixed vault/controller; the controller makes only static reads.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function close(S.Data storage s, address user, uint256 fraction, uint256 limitPrice, bytes32[] memory proof)
        public
    {
        Engine.touch(s);
        int256 fundingOwed = Engine.settleFunding(s, user);
        S.CloseQuote memory q = Lens.quoteClose(s, user, fraction);
        Engine.checkLimit(-q.closedSize, q.fill.avgPrice, limitPrice);
        s.vault.checkAndConsume(user, msg.sender, q.fill.quoteAmount, true, proof);
        Engine.applyClose(s, user, q);
        Engine.chargeFee(s, user, q.fee, true);
        // Exact position-size arithmetic must detect the final close to clear its snapshot and residual entry cost.
        // slither-disable-next-line incorrect-equality
        if (s._positions[user].size == 0) {
            // Coverage emits per-source debt events; the total is needed only by the liquidation event.
            // slither-disable-next-line unused-return
            Engine.coverDebt(s, user);
            s.vault.release(user, F.toUint(s.vault.locked(user, address(this))));
            delete s._positions[user];
        }
        // Partial closes retain collateral. The owner can remove the excess subject to the initial-margin checks.
        emit IMarketCore.PositionClosed(
            address(this), user, msg.sender, q.closedSize, q.fill.avgPrice, q.pnl, fundingOwed, q.fee
        );
    }
}
