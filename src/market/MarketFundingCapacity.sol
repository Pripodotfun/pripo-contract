// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketCore} from "../interfaces/IMarketCore.sol";
import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {FixedPointMath as F} from "../libraries/FixedPointMath.sol";
import {FundingCapacityHeap as Heap} from "../libraries/FundingCapacityHeap.sol";
import {FundingMath as Funding} from "../libraries/FundingMath.sol";
import {RiskMath as Risk} from "../libraries/RiskMath.sol";
import {PripoTypes as T} from "../types/PripoTypes.sol";
import {MarketState as S} from "./MarketState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Funding may spend only this position's margin above protected trading collateral.
library MarketFundingCapacity {
    using Heap for Heap.State;

    function protectedCollateral(S.Data storage s, int256 size, uint256 entry) public view returns (uint256) {
        if (size == 0) return 0;
        uint256 worst = Risk.worstClose(s._amm, size > 0, F.abs(size), s._config.sideCapBps);
        uint256 loss = size > 0 ? (entry > worst ? entry - worst : 0) : (worst > entry ? worst - entry : 0);
        uint256 maintenance = Math.mulDiv(entry, s._config.mmrBps, F.BPS, Math.Rounding.Ceil);
        uint256 exitFee = Math.mulDiv(worst, s._config.takerFeeBps, F.BPS, Math.Rounding.Ceil);
        return loss + maintenance + exitFee;
    }

    function account(S.Data storage s, address user)
        public
        view
        returns (int256 capIndex, uint256 protectedAmount, uint256 capacity)
    {
        T.Position memory p = s._positions[user];
        if (p.size == 0) return (type(int256).max, 0, 0);
        protectedAmount = protectedCollateral(s, p.size, p.entryCost);
        int256 locked = s.vault.locked(user, address(this));
        capacity = locked > F.toInt(protectedAmount) ? F.toUint(locked) - protectedAmount : 0;
        capIndex = p.lastFundingIndex + F.toInt(Math.mulDiv(capacity, F.WAD, F.abs(p.size)));
    }

    function minimum(S.Data storage s, bool isLong) public view returns (address, int256) {
        // The selected heap's complete tuple is returned, including its empty sentinel.
        // slither-disable-next-line unused-return
        return isLong ? s.longFundingCaps.minimum() : s.shortFundingCaps.minimum();
    }

    /// @dev Caller has already applied market status, oracle age and pending-ADL rate suppression.
    function preview(S.Data storage s, T.FundingState memory f, int256 rate, uint256 price, uint64 end)
        public
        view
        returns (T.FundingState memory, address binding)
    {
        binding = s.fundingBinding;
        if (binding != address(0) || rate == 0 || s.longSize == 0 || s.shortSize == 0 || end <= f.lastBlock) {
            return (f, binding);
        }
        (address user, int256 cap) = minimum(s, rate > 0);
        if (user == address(0)) revert E.AccountingInvariant();
        int256 index = rate > 0 ? f.longIndex : f.shortIndex;
        uint256 headroom = cap > index ? F.toUint(cap - index) : 0;
        f = Funding.accrueCapped(f, s.longSize, s.shortSize, rate, price, end, s._config.receiveCapX, headroom);
        int256 advanced = rate > 0 ? f.longIndex : f.shortIndex;
        if (advanced >= cap) binding = user;
        return (f, binding);
    }

    function latch(S.Data storage s, address binding) public {
        if (binding == address(0) || s.fundingBinding != address(0)) return;
        s.fundingBinding = binding;
        emit IMarketCore.FundingCapacityFrozen(address(this), binding);
    }

    /// @notice Invoke after every position/collateral mutation, after all fees, coverage and releases.
    function refresh(S.Data storage s, address user) public {
        T.Position memory p = s._positions[user];
        (int256 cap,,) = account(s, user);
        if (p.size > 0) {
            s.longFundingCaps.set(user, cap);
            s.shortFundingCaps.remove(user);
        } else if (p.size < 0) {
            s.shortFundingCaps.set(user, cap);
            s.longFundingCaps.remove(user);
        } else {
            s.longFundingCaps.remove(user);
            s.shortFundingCaps.remove(user);
        }
        if (s.fundingBinding == user) {
            int256 index = p.size > 0 ? s._funding.longIndex : s._funding.shortIndex;
            if (p.size == 0 || cap > index) {
                s.fundingBinding = address(0);
                emit IMarketCore.FundingCapacityResumed(address(this), user);
            }
        }
    }

    function checkDebit(S.Data storage s, address user, int256 owed) public view {
        if (owed <= 0) return;
        (,, uint256 capacity) = account(s, user);
        if (F.toUint(owed) > capacity) revert E.FundingCapacityExceeded(user, F.toUint(owed), capacity);
    }

    /// @dev Repeated partial-close fee rounding must not spend collateral backing the remaining curve exposure.
    function checkExitCollateral(S.Data storage s, address user) public view {
        T.Position memory p = s._positions[user];
        if (p.size == 0) return;
        uint256 required = protectedCollateral(s, p.size, p.entryCost)
            - Math.mulDiv(p.entryCost, s._config.mmrBps, F.BPS, Math.Rounding.Ceil);
        int256 collateral = s.vault.locked(user, address(this));
        if (collateral < F.toInt(required)) {
            revert E.InsufficientMargin(collateral > 0 ? F.toUint(collateral) : 0, required);
        }
    }
}
