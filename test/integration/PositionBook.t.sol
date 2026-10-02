// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract PositionBookTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function testOpenIncreasePartialCloseStableRemovalAndFreeListReuse() public {
        _open(alice, 1e18);
        _open(bob, -1e18);
        _open(carol, 1e18);
        _open(alice, 1e18);
        assertEq(market.positionCount(), 3);
        _close(alice, 0.5e18);
        assertEq(market.positionCount(), 3);
        _close(bob, 1e18);
        address[] memory users = market.positionAccounts(0, 256);
        assertEq(users.length, 3);
        assertEq(users[0], alice);
        assertEq(users[1], address(0));
        assertEq(users[2], carol);
        _close(carol, 1e18);
        _open(bob, 1e18);
        users = market.positionAccounts(2, 1);
        assertEq(users.length, 1);
        assertEq(users[0], bob);
        assertEq(market.positionAccounts(type(uint256).max, 256).length, 0);
        assertEq(market.positionAccounts(0, 0).length, 0);
        vm.expectPartialRevert(E.PositionLimit.selector);
        market.positionAccounts(0, 257);
        _assertCash();
    }

    function testPositionCapAllowsIncreasesAndFreesSlotOnlyOnFullClose() public {
        for (uint256 i; i < 128; ++i) {
            address user = address(uint160(0x10000 + i));
            _deposit(user, 20e6);
            _open(user, i % 2 == 0 ? int256(0.1e18) : -int256(0.1e18));
        }
        assertEq(market.positionCount(), market.MAX_POSITIONS());
        address[] memory users = market.positionAccounts(0, 256);
        for (uint256 i; i < users.length; ++i) {
            assertTrue(market.position(users[i]).size != 0);
        }
        bytes32 beforeState = keccak256(abi.encode(market.ammState(), vault.freeBalance(alice), market.fundingState()));
        vm.prank(alice);
        vm.expectPartialRevert(E.PositionLimit.selector);
        market.open(1e18, type(uint256).max, "");
        assertEq(keccak256(abi.encode(market.ammState(), vault.freeBalance(alice), market.fundingState())), beforeState);
        _open(users[0], 0.1e18);
        _close(users[1], 0.5e18);
        assertEq(market.positionCount(), 128);
        _close(users[1], 1e18);
        _open(alice, 1e18);
        assertEq(market.positionCount(), 128);
    }

    function testFullLiquidationRemovesBookEntry() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 3_000_000);
        market.liquidate(alice, "");
        assertEq(market.positionCount(), 1);
        assertEq(market.positionAccounts(0, 1)[0], address(0));
        assertEq(market.positionAccounts(1, 1)[0], bob);
        _assertCash();
    }
}
