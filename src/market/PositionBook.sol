// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";
import {MarketState as S} from "./MarketState.sol";

/// @notice Bounded enumeration of nonempty positions. Indices are unstable after a removal.
library PositionBook {
    uint256 internal constant MAX_POSITIONS = 256;

    function add(S.Data storage s, address user) internal {
        if (s._accountIndex[user] != 0) revert E.AccountingInvariant();
        if (s._accounts.length >= MAX_POSITIONS) revert E.PositionLimit(MAX_POSITIONS);
        s._accounts.push(user);
        s._accountIndex[user] = s._accounts.length;
    }

    function remove(S.Data storage s, address user) internal {
        uint256 index = s._accountIndex[user];
        if (index == 0) revert E.AccountingInvariant();
        uint256 last = s._accounts.length;
        if (index != last) {
            address moved = s._accounts[last - 1];
            s._accounts[index - 1] = moved;
            s._accountIndex[moved] = index;
        }
        s._accounts.pop();
        delete s._accountIndex[user];
    }

    function page(S.Data storage s, uint256 offset, uint256 limit) internal view returns (address[] memory users) {
        if (limit > MAX_POSITIONS) revert E.PositionLimit(MAX_POSITIONS);
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
