// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "./MarketFixture.sol";

abstract contract AdlFixture is MarketFixture {
    function _prepare(bool short) internal {
        _prepareSplit(short, 20e18);
    }

    function _prepareSplit(bool short, uint256 bobSize) internal {
        int256 side = short ? -int256(1) : int256(1);
        _open(alice, side * 10e18);
        _open(carol, side * 10e18);
        _open(bob, -side * int256(bobSize));
        if (bobSize != 20e18) _open(creator, -side * int256(20e18 - bobSize));
        _open(carol, side * 1e18);
        vm.roll(block.number + 30_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 current = vault.locked(alice, address(market)) - owed;
        uint256 capacity = vault.ledger(address(market)).insurance;
        int256 desired = -int256(capacity) + 0.5e18;
        assertLt(current, desired);
        vm.prank(alice);
        market.addMargin(uint256(desired - current));
        (, bool unhealthy) = market.health(alice);
        assertTrue(unhealthy);
        (,, int256 pnl,) = market.quoteClose(alice, 1e18);
        assertGt(uint256(-vault.locked(alice, address(market)) - pnl), capacity);
    }
}
