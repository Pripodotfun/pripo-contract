// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {MarketState as S} from "./MarketState.sol";

/// @notice Bounded lifetime slots. Closing an account leaves a hole and never moves another account.
library PositionBook {
    uint256 internal constant MAX_POSITIONS = 128;
    uint256 internal constant MAX_PAGE_SIZE = 256;

    function add(S.Data storage s, address user) internal {
        if (s._accountIndex[user] != 0) revert E.AccountingInvariant();
        if (s._positionCount >= MAX_POSITIONS) revert E.PositionLimit(MAX_POSITIONS);
        uint256 slot;
        if (s._freeSlots.length == 0) {
            slot = s._accounts.length;
            s._accounts.push(user);
        } else {
            slot = s._freeSlots[s._freeSlots.length - 1];
            s._freeSlots.pop();
            s._accounts[slot] = user;
        }
        s._accountIndex[user] = slot + 1;
        ++s._positionCount;
    }

    function remove(S.Data storage s, address user) internal {
        uint256 index = s._accountIndex[user];
        if (index == 0) revert E.AccountingInvariant();
        delete s._accounts[index - 1];
        s._freeSlots.push(index - 1);
        delete s._accountIndex[user];
        --s._positionCount;
    }

    /// @dev Compact snapshot for atomic whole-book operations; order is ascending stable slot.
    function live(S.Data storage s) internal view returns (address[] memory users) {
        users = new address[](s._positionCount);
        uint256 count;
        for (uint256 i; i < s._accounts.length; ++i) {
            if (s._accounts[i] != address(0)) users[count++] = s._accounts[i];
        }
        if (count != users.length) revert E.AccountingInvariant();
    }

    function page(S.Data storage s, uint256 offset, uint256 limit) internal view returns (address[] memory users) {
        if (limit > MAX_PAGE_SIZE) revert E.PositionLimit(MAX_PAGE_SIZE);
        uint256 count = s._accounts.length;
        if (offset >= count) return new address[](0);
        uint256 length = count - offset;
        if (limit < length) length = limit;
        users = new address[](length);
        for (uint256 i; i < length; ++i) {
            users[i] = s._accounts[offset + i];
        }
    }
}
