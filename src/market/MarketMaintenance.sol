// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarginVault} from "../interfaces/IMarginVault.sol";
import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {CurveMath as Curve} from "../libraries/CurveMath.sol";
import {MarkTwap} from "../libraries/MarkTwap.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketState as S} from "./MarketState.sol";

/// @notice Administrative and oracle maintenance transitions under the market entry-point guard.
library MarketMaintenance {
    using MarkTwap for MarkTwap.State;

    /// @notice Called only under Market's initializer and reentrancy guard; registrar checks remain atomic.
    function initialize(
        S.Data storage s,
        IMarginVault vault_,
        bytes32 feedId_,
        bool externalIndex_,
        T.MarketConfig calldata cfg,
        uint256 initialPrice,
        uint256 depth,
        uint256 marketNotionalCap
    ) public {
        if (address(vault_).code.length == 0 || vault_.registrarOf(address(this)) != msg.sender) revert E.Unauthorized();
        if (cfg.creator != vault_.creatorOf(address(this))) revert E.InvalidConfiguration();
        s.vault = vault_;
        s.feedId = feedId_;
        s.externalIndex = externalIndex_;
        Engine.validateConfig(s, cfg);
        s._config = cfg;
        s._config.status = T.Status.Active;
        s._config.statusSince = Engine.currentBlock();
        if (s.externalIndex) {
            Engine.refreshPrice(s, "", 0);
            initialPrice = s._index;
        }
        s._amm = Curve.seed(initialPrice, depth);
        Engine.validateDepth(s, depth);
        s._funding.lastBlock = Engine.currentBlock();
        s._twap.initialize(Curve.mark(s._amm), Engine.currentBlock());
        if (s.handoffEconomics) s.vault.setInsuranceCap(s.seedBond * 10);
        s.vault.admitMarket(marketNotionalCap, cfg.fundingCapPerBlock);
    }

    function poke(S.Data storage s) public {
        Engine.touch(s);
        if (s.externalIndex) {
            S.Observation memory o = Engine.readSource(s, s._config.priceSource, "", 0);
            if (!Engine.fresh(s, o) && s._config.secondarySource != address(0)) {
                o = Engine.readSource(s, s._config.secondarySource, "", 0);
            }
            if (Engine.fresh(s, o)) {
                s._index = o.price;
                s._indexBlock = o.updatedBlock;
                if (!s.guardianPaused && s.pendingAdlCount == 0) Engine.setStatus(s, T.Status.Active);
            }
        }
    }

    function remark(S.Data storage s, bytes memory update, uint256 value) public {
        Engine.touch(s);
        Engine.refreshPrice(s, update, value);
        s.lastTradeTimestamp = uint64(block.timestamp);
        if (!s.guardianPaused && s.pendingAdlCount == 0) Engine.setStatus(s, T.Status.Active);
    }

    function pauseOpens(S.Data storage s) public {
        if (msg.sender != s.vault.guardian()) revert E.Unauthorized();
        Engine.touch(s);
        s.guardianPaused = true;
        Engine.setStatus(s, T.Status.Paused);
    }

    function resumeOpens(S.Data storage s) public {
        if (msg.sender != s.vault.governor()) revert E.Unauthorized();
        s.vault.requireOpenAllowed(address(this));
        Engine.touch(s);
        s.guardianPaused = false;
        Engine.setStatus(
            s, s.pendingAdlCount != 0 ? T.Status.Paused : Engine.isDegraded(s) ? T.Status.Degraded : T.Status.Active
        );
    }

    // The market entry point holds nonReentrant through the fixed vault's guarded token transfer and this event.
    // slither-disable-next-line reentrancy-events
    function claimCreatorFees(S.Data storage s) public {
        if (msg.sender != s._config.creator) revert E.Unauthorized();
        uint256 amount = s.vault.claimCreatorFees();
        emit IMarketCore.CreatorFeesClaimed(address(this), msg.sender, amount);
    }

    // The market entry point holds nonReentrant; the fixed vault performs a ledger-only role update.
    // slither-disable-next-line reentrancy-events
    function transferCreator(S.Data storage s, address to) public {
        if (msg.sender != s._config.creator) revert E.Unauthorized();
        if (to == address(0)) revert E.InvalidAddress();
        s._config.creator = to;
        s.vault.transferCreator(to);
        emit IMarketCore.CreatorTransferred(msg.sender, to);
    }

    function reseed(S.Data storage s, uint256 depth) public {
        if (msg.sender != s._config.creator) revert E.Unauthorized();
        if (s.longSize != 0 || s.shortSize != 0) revert E.PositionExists();
        if (Curve.clearing(s._amm) != 0 || s.vault.ledger(address(this)).clearing != 0) revert E.AccountingInvariant();
        Engine.touch(s);
        s._amm = Curve.seed(Curve.mark(s._amm), depth);
        Engine.validateDepth(s, depth);
        s._twap.write(Curve.mark(s._amm), Engine.currentBlock());
    }
}
