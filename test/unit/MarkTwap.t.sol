// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MarkTwap} from "../../src/libraries/MarkTwap.sol";
import {Test} from "forge-std/Test.sol";

contract MarkTwapTest is Test {
    using MarkTwap for MarkTwap.State;
    MarkTwap.State private state;

    function testElapsedBlocksAndSameBlockReplacement() public {
        state.initialize(100e18, 1);
        state.write(150e18, 1);
        assertEq(state.consult(300, 1), 100e18);
        assertEq(state.consult(300, 101), 150e18);
        state.write(200e18, 101);
        state.write(250e18, 101);
        assertEq(state.consult(300, 201), 200e18);
        assertEq(state.consult(300, 501), 250e18);
    }

    function testRingWrapKeepsEntireLongestWindow() public {
        state.initialize(1e18, 1);
        for (uint64 i = 2; i <= 1_500; i++) {
            state.write(uint256(i) * 1e18, i);
        }
        // Integral across blocks [900,1500): prices 900,901,...,1499.
        assertEq(state.consult(600, 1_500), (uint256(900) + 1499) * 1e18 / 2);
        assertEq(state.consult(300, 1_500), (uint256(1200) + 1499) * 1e18 / 2);
        assertEq(state.consult(600, 2_500), 1_500e18);
    }

    function testSparseSamplesAndWindowInterpolation() public {
        state.initialize(100e18, 10);
        state.write(200e18, 310);
        assertEq(state.consult(300, 460), 150e18);
        state.write(50e18, 10_000);
        assertEq(state.consult(600, 10_300), 125e18);
    }
}
