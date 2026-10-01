// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";

contract MarketAdlTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function testPairedLongClosePreservesCurveAndReleasesPartialWinnerMargin() public {
        _paired(false, false);
    }

    function testPairedShortClosePreservesCurveAndReleasesPartialWinnerMargin() public {
        _paired(true, false);
    }

    function testExplicitEligibleCandidatesExecutePairing() public {
        _paired(false, true);
    }

    function testOmittedEligibleCandidateCannotForceSettlementAndRollsBack() public {
        _prepare(false);
        bytes32 beforeState = _state();
        vm.expectRevert(E.IncompleteAdlCandidates.selector);
        market.liquidate(alice, "", new address[](0));
        assertEq(_state(), beforeState);
        address[] memory invalid = new address[](1);
        invalid[0] = alice;
        vm.expectRevert(E.InvalidAdlCandidates.selector);
        market.liquidate(alice, "", invalid);
        assertEq(_state(), beforeState);
        address[] memory duplicates = new address[](2);
        duplicates[0] = bob;
        duplicates[1] = bob;
        vm.expectRevert(E.InvalidAdlCandidates.selector);
        market.liquidate(alice, "", duplicates);
        assertEq(_state(), beforeState);
    }

    function testMultipleCandidatesOrderingAndTruncatedList() public {
        _prepareSplit(false, 8e18);
        address[] memory candidates = new address[](2);
        candidates[0] = creator;
        candidates[1] = bob;
        bytes32 beforeState = _state();
        vm.expectRevert(E.InvalidAdlCandidates.selector);
        market.liquidate(alice, "", candidates);
        assertEq(_state(), beforeState);
        candidates = new address[](1);
        candidates[0] = bob;
        vm.expectRevert(E.IncompleteAdlCandidates.selector);
        market.liquidate(alice, "", candidates);
        assertEq(_state(), beforeState);
        candidates = new address[](2);
        candidates[0] = bob;
        candidates[1] = creator;
        T.AmmState memory beforeAmm = market.ammState();
        market.liquidate(alice, "", candidates);
        assertEq(market.position(alice).size, 0);
        assertEq(market.position(bob).size, 0);
        assertEq(market.position(creator).size, -10e18);
        assertEq(market.ammState().baseReserve, beforeAmm.baseReserve);
        assertEq(market.ammState().quoteReserve, beforeAmm.quoteReserve);
        _assertCash();
    }

    function testRoundedRemainderRebalancesAtPositionLimit() public {
        _open(alice, 10e18);
        _open(carol, 10e18);
        for (uint256 i; i < 126; ++i) {
            address winner = address(uint160(0x30000 + i));
            _deposit(winner, 20e6);
            _open(winner, -int256(uint256(20e18) / 126));
        }
        _open(carol, 1e18);
        vm.roll(block.number + 30_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 current = vault.locked(alice, address(market)) - owed;
        int256 desired = -int256(vault.ledger(address(market)).insurance) + 0.5e18;
        vm.prank(alice);
        market.addMargin(uint256(desired - current));
        // Sixty-three equal matches leave one base wei. Resize the boundary pair so both slices earn profit.
        T.AmmState memory beforeAmm = market.ammState();
        uint256 reserve = vault.protocolReserve();
        uint256 gasBefore = gasleft();
        market.liquidate(alice, "");
        emit log_named_uint("128-position book with rounded boundary redistribution gas", gasBefore - gasleft());
        assertLt(gasBefore - gasleft(), 20_000_000);
        assertEq(market.position(alice).size, 0);
        assertEq(market.positionCount(), 65);
        assertEq(market.ammState().baseReserve, beforeAmm.baseReserve);
        assertEq(market.ammState().quoteReserve, beforeAmm.quoteReserve);
        assertEq(vault.protocolReserve(), reserve);
        assertEq(vault.totalDeficit(), 0);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
        T.Ledger memory l = vault.ledger(address(market));
        int256 cash = int256(
            vault.freeBalance(alice) + vault.freeBalance(bob) + vault.freeBalance(carol) + vault.freeBalance(creator)
                + reserve + l.insurance + l.creatorOwed + l.protocolOwed
        ) + vault.locked(carol, address(market)) + l.clearing + l.fundingPool;
        for (uint256 i; i < 126; ++i) {
            address winner = address(uint160(0x30000 + i));
            cash += int256(vault.freeBalance(winner)) + vault.locked(winner, address(market));
        }
        assertEq(cash, int256(usdc.balanceOf(address(vault)) * 1e12));
    }

    function testExplicitRoundedBoundaryRebalancesLongTarget() public {
        _roundedPair(false);
    }

    function testExplicitRoundedBoundaryRebalancesShortTarget() public {
        _roundedPair(true);
    }

    function _roundedPair(bool short) internal {
        _prepareSplit(short, 10e18 - 1);
        address[] memory candidates = new address[](2);
        candidates[0] = bob;
        candidates[1] = creator;
        uint256 beforeBob = vault.freeBalance(bob);
        uint256 beforeCreator = vault.freeBalance(creator);
        int256 sizeBob = market.position(bob).size;
        int256 sizeCreator = market.position(creator).size;
        T.AmmState memory beforeAmm = market.ammState();
        market.liquidate(alice, "", candidates);
        assertEq(market.position(alice).size, 0);
        // Both boundary winners remain open; the final winner receives more than the failed one-base-wei slice.
        assertTrue(market.position(bob).size != 0);
        int256 bobClosed = sizeBob - market.position(bob).size;
        int256 creatorClosed = sizeCreator - market.position(creator).size;
        assertEq(bobClosed + creatorClosed, short ? int256(10e18) : -int256(10e18));
        assertGt(short ? creatorClosed : -creatorClosed, 1);
        assertGt(vault.freeBalance(bob), beforeBob);
        assertGt(vault.freeBalance(creator), beforeCreator);
        assertEq(market.ammState().baseReserve, beforeAmm.baseReserve);
        assertEq(market.ammState().quoteReserve, beforeAmm.quoteReserve);
        assertEq(vault.totalDeficit(), 0);
        _assertCash();
    }

    function _paired(bool short, bool explicit) internal {
        _prepare(short);
        T.AmmState memory beforeAmm = market.ammState();
        uint256 reserve = vault.protocolReserve();
        uint256 beforeFree = vault.freeBalance(bob);
        uint256 beforeLocked = uint256(vault.locked(bob, address(market)));
        uint256 insurance = vault.ledger(address(market)).insurance;
        if (explicit) {
            address[] memory candidates = new address[](1);
            candidates[0] = bob;
            market.liquidate(alice, "", candidates);
        } else {
            market.liquidate(alice, "");
        }
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Active));
        T.AmmState memory afterAmm = market.ammState();
        assertEq(afterAmm.baseReserve, beforeAmm.baseReserve);
        assertEq(afterAmm.quoteReserve, beforeAmm.quoteReserve);
        assertEq(afterAmm.k, beforeAmm.k);
        assertEq(market.position(alice).size, 0);
        assertEq(market.positionDebt(alice), 0);
        assertEq(market.position(bob).size, short ? int256(10e18) : -int256(10e18));
        assertGt(vault.freeBalance(bob) - beforeFree, beforeLocked / 2);
        assertLt(vault.ledger(address(market)).insurance, insurance);
        assertEq(vault.protocolReserve(), reserve);
        assertEq(vault.totalDeficit(), 0);
        assertEq(market.positionCount(), 2);
        _assertCash();
        T.FundingState memory funding = market.fundingState();
        Funding.surplus(funding, vault.ledger(address(market)).fundingPool, market.longSize(), market.shortSize());
    }

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

    function _state() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                market.ammState(),
                market.fundingState(),
                vault.ledger(address(market)),
                market.position(alice),
                market.position(bob),
                vault.freeBalance(bob)
            )
        );
    }
}
