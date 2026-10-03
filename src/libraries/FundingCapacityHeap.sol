// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../interfaces/IPripoErrors.sol";

/// @notice Bounded minimum index per side, with one mutable entry per live position.
/// @dev Indexed updates/removals prevent stale entries from accumulating across repeated position touches.
library FundingCapacityHeap {
    uint256 internal constant MAX_ENTRIES = 128;

    struct Node {
        address user;
        int256 capIndex;
    }

    struct State {
        Node[] nodes;
        mapping(address => uint256) indexPlusOne;
    }

    function minimum(State storage h) internal view returns (address user, int256 capIndex) {
        if (h.nodes.length == 0) return (address(0), type(int256).max);
        Node storage n = h.nodes[0];
        return (n.user, n.capIndex);
    }

    function set(State storage h, address user, int256 capIndex) internal {
        if (user == address(0)) revert E.InvalidAddress();
        uint256 index = h.indexPlusOne[user];
        if (index == 0) {
            if (h.nodes.length >= MAX_ENTRIES) revert E.InvalidSize();
            index = h.nodes.length;
            h.nodes.push(Node({user: user, capIndex: capIndex}));
            h.indexPlusOne[user] = index + 1;
        } else {
            --index;
            h.nodes[index].capIndex = capIndex;
        }
        _repair(h, index);
    }

    function remove(State storage h, address user) internal {
        uint256 index = h.indexPlusOne[user];
        if (index == 0) return;
        --index;
        uint256 last = h.nodes.length - 1;
        if (index != last) {
            h.nodes[index] = h.nodes[last];
            h.indexPlusOne[h.nodes[index].user] = index + 1;
        }
        h.nodes.pop();
        delete h.indexPlusOne[user];
        if (index < last) _repair(h, index);
    }

    function _repair(State storage h, uint256 index) private {
        if (index != 0 && _less(h.nodes[index], h.nodes[(index - 1) / 2])) {
            while (index != 0) {
                uint256 parent = (index - 1) / 2;
                if (!_less(h.nodes[index], h.nodes[parent])) break;
                _swap(h, index, parent);
                index = parent;
            }
        } else {
            uint256 count = h.nodes.length;
            while (2 * index + 1 < count) {
                uint256 child = 2 * index + 1;
                if (child + 1 < count && _less(h.nodes[child + 1], h.nodes[child])) ++child;
                if (!_less(h.nodes[child], h.nodes[index])) break;
                _swap(h, index, child);
                index = child;
            }
        }
    }

    function _less(Node memory a, Node memory b) private pure returns (bool) {
        return a.capIndex < b.capIndex || (a.capIndex == b.capIndex && a.user < b.user);
    }

    function _swap(State storage h, uint256 a, uint256 b) private {
        Node memory old = h.nodes[a];
        h.nodes[a] = h.nodes[b];
        h.nodes[b] = old;
        h.indexPlusOne[h.nodes[a].user] = a + 1;
        h.indexPlusOne[h.nodes[b].user] = b + 1;
    }
}
