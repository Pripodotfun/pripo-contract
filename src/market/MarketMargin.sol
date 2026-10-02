// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketAccounting as Engine} from "./MarketAccounting.sol";
import {MarketAdl as Adl} from "./MarketAdl.sol";
import {MarketState as S} from "./MarketState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Margin changes under the market guard, including replacement of unspent pending coverage.
library MarketMargin {
    // All entry points hold the market guard; the fixed vault's lock/replacement methods only move ledger balances.
    // slither-disable-next-line reentrancy-events
    function addMargin(S.Data storage s, uint256 amount) public {
        if (amount == 0) revert E.ZeroAmount();
        if (s._positions[msg.sender].size == 0) revert E.NoPosition();
        Engine.touch(s);
        // Settlement effects are required; only close events need the returned debit.
        // slither-disable-next-line unused-return
        Engine.settleFunding(s, msg.sender);
        s.vault.lock(msg.sender, amount);
        Adl.replaceCoverage(s, msg.sender, amount);
        emit IMarketCore.MarginChanged(address(this), msg.sender, F.toInt(amount));
    }

    // The market guard remains held through the fixed vault's ledger-only release.
    // slither-disable-next-line reentrancy-events
    function removeMargin(S.Data storage s, uint256 amount) public {
        if (amount == 0) revert E.ZeroAmount();
        if (s._pendingAdl[msg.sender].active) revert E.AdlAlreadyPending();
        T.Position memory p = s._positions[msg.sender];
        if (p.size == 0) revert E.NoPosition();
        Engine.touch(s);
        // Settlement effects are required; only close events need the returned debit.
        // slither-disable-next-line unused-return
        Engine.settleFunding(s, msg.sender);
        uint256 required = Engine.initialMargin(s, p.size, p.entryCost);
        int256 remaining = s.vault.locked(msg.sender, address(this)) - F.toInt(amount);
        if (remaining < F.toInt(required)) {
            revert E.InsufficientMargin(remaining > 0 ? F.toUint(remaining) : 0, required);
        }
        int256 equity = remaining + Engine.referencePnl(s, p);
        uint256 minimum = Math.ceilDiv(p.entryCost, s._config.maxLeverageX);
        if (equity < F.toInt(minimum)) revert E.InsufficientMargin(equity > 0 ? F.toUint(equity) : 0, minimum);
        s.vault.release(msg.sender, amount);
        emit IMarketCore.MarginChanged(address(this), msg.sender, -F.toInt(amount));
    }
}
