// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FundingCapacityHeap as Heap} from "../../src/libraries/FundingCapacityHeap.sol";
import {Test} from "forge-std/Test.sol";

contract FundingCapacityHeapHarness {
    using Heap for Heap.State;
    Heap.State private h;

    function set(address user, int256 capIndex) external {
        h.set(user, capIndex);
    }

    function remove(address user) external {
        h.remove(user);
    }

    function minimum() external view returns (address, int256) {
        return h.minimum();
    }

    function nodes() external view returns (Heap.Node[] memory) {
        return h.nodes;
    }

    function indexPlusOne(address user) external view returns (uint256) {
        return h.indexPlusOne[user];
    }
}

contract FundingCapacityHeapTest is Test {
    FundingCapacityHeapHarness private h;

    function setUp() public {
        h = new FundingCapacityHeapHarness();
    }

    function testSignedKeysTiesRootUpdatesAndAbsentRemoval() public {
        h.set(address(3), -20);
        h.set(address(2), -20);
        h.set(address(1), type(int256).min);
        _minimum(address(1), type(int256).min);
        h.set(address(1), type(int256).max);
        _minimum(address(2), -20);
        h.remove(address(2));
        _minimum(address(3), -20);
        h.remove(address(3));
        _minimum(address(1), type(int256).max);
        h.remove(address(1));
        h.remove(address(1));
        _minimum(address(0), type(int256).max);
        assertEq(h.indexPlusOne(address(1)), 0);
    }

    function testUpdatesStayBoundedAtFullBookAndClosedSlotsCanBeReused() public {
        for (uint160 i = 1; i <= 128; ++i) {
            h.set(address(i), int256(uint256(i)));
        }
        for (uint256 i; i < 256; ++i) {
            h.set(address(1), int256(i));
        }
        assertEq(h.nodes().length, 128);
        _minimum(address(2), 2);
        vm.expectRevert(E.InvalidSize.selector);
        h.set(address(129), -1);
        h.remove(address(64));
        h.set(address(129), -1);
        assertEq(h.nodes().length, 128);
        assertEq(h.indexPlusOne(address(64)), 0);
        _minimum(address(129), -1);
        vm.expectRevert(E.InvalidAddress.selector);
        h.set(address(0), 0);
    }

    function testFuzzMinimumMatchesFullScanAfterEveryMutation(uint256 seed, uint8 countSeed) public {
        uint256 count = bound(countSeed, 1, 128);
        int256[] memory caps = new int256[](count);
        bool[] memory live = new bool[](count);
        for (uint256 step; step < 64; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 slot = seed % count;
            address user = address(uint160(slot + 1));
            if ((seed >> 128) % 4 == 0) {
                h.remove(user);
                live[slot] = false;
            } else {
                int256 value = int256(seed % 2_000_001) - 1_000_000;
                h.set(user, value);
                caps[slot] = value;
                live[slot] = true;
            }
            _check(caps, live);
        }
    }

    function _check(int256[] memory caps, bool[] memory live) private view {
        address expectedUser;
        int256 expectedCap = type(int256).max;
        uint256 count;
        Heap.Node[] memory nodes = h.nodes();
        for (uint256 i; i < caps.length; ++i) {
            address user = address(uint160(i + 1));
            uint256 index = h.indexPlusOne(user);
            if (!live[i]) {
                assertEq(index, 0);
                continue;
            }
            ++count;
            assertGt(index, 0);
            assertEq(nodes[index - 1].user, user);
            assertEq(nodes[index - 1].capIndex, caps[i]);
            if (expectedUser == address(0) || caps[i] < expectedCap) {
                expectedUser = user;
                expectedCap = caps[i];
            }
        }
        assertEq(nodes.length, count);
        _minimum(expectedUser, expectedCap);
        for (uint256 i = 1; i < nodes.length; ++i) {
            Heap.Node memory parent = nodes[(i - 1) / 2];
            assertTrue(
                parent.capIndex < nodes[i].capIndex
                    || (parent.capIndex == nodes[i].capIndex && parent.user < nodes[i].user)
            );
        }
    }

    function _minimum(address user, int256 cap) private view {
        (address actualUser, int256 actualCap) = h.minimum();
        assertEq(actualUser, user);
        assertEq(actualCap, cap);
    }
}
