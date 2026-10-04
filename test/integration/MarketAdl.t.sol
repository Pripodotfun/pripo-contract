// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FundingMath as Funding} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {AdlFixture} from "../helpers/AdlFixture.sol";

contract MarketAdlTest is AdlFixture {
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

    function testOmittedEligibleCandidateLeavesPendingAndInvalidListsRollBack() public {
        _prepare(false);
        bytes32 beforeState = _state();
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
        market.liquidate(alice, "", new address[](0));
        assertTrue(market.pendingAdl(alice).active);
        assertEq(market.pendingAdl(alice).matchedSize, 0);
        assertEq(market.pendingAdlCount(), 1);
        (uint8 status,) = market.status();
        assertEq(status, uint8(T.Status.Paused));
        _assertCash();
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
        T.AmmState memory beforeAmm = market.ammState();
        market.liquidate(alice, "", candidates);
        assertEq(market.pendingAdl(alice).matchedSize, 8e18);
        assertEq(market.position(bob).size, 0);
        _assertCash();
        candidates[0] = creator;
        market.continueAdl(alice, candidates);
        assertEq(market.position(alice).size, 0);
        assertEq(market.position(bob).size, 0);
        assertEq(market.position(creator).size, -10e18);
        assertEq(market.ammState().baseReserve, beforeAmm.baseReserve);
        assertEq(market.ammState().quoteReserve, beforeAmm.quoteReserve);
        _assertCash();
    }

    function testRoundedRemainderMatchesGreedilyAtPositionLimit() public {
        _open(alice, 10e18);
        _open(carol, 10e18);
        for (uint256 i; i < 126; ++i) {
            address winner = address(uint160(0x30000 + i));
            _deposit(winner, 20e6);
            _open(winner, -int256(uint256(20e18) / 126));
        }
        _open(carol, 1e18);
        _seedLegacyFundingDebt(block.number + 30_000_000);
        _close(carol, uint256(2e18) / 11);
        vm.roll(block.number + 300);
        (,,, int256 owed) = market.quoteClose(alice, 1e18);
        int256 current = vault.locked(alice, address(market)) - owed;
        int256 desired = -int256(vault.ledger(address(market)).insurance) + 0.5e18;
        vm.prank(alice);
        market.addMargin(uint256(desired - current));
        // Sixty-three full matches leave one base wei; the final match is paid through winner rounding/top-up.
        T.AmmState memory beforeAmm = market.ammState();
        uint256 reserve = vault.protocolReserve();
        uint256 gasBefore = gasleft();
        market.liquidate(alice, "");
        emit log_named_uint("128-position book with greedy dust boundary gas", gasBefore - gasleft());
        assertLt(gasBefore - gasleft(), 20_000_000);
        assertEq(market.position(alice).size, 0);
        assertEq(market.positionCount(), 64);
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

    function testExplicitRoundedBoundaryMatchesLongTarget() public {
        _roundedPair(false);
    }

    function testExplicitRoundedBoundaryMatchesShortTarget() public {
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
        // Greedy consumes the first winner exactly; the final winner takes one base wei.
        assertEq(market.position(bob).size, 0);
        int256 bobClosed = sizeBob - market.position(bob).size;
        int256 creatorClosed = sizeCreator - market.position(creator).size;
        assertEq(bobClosed + creatorClosed, short ? int256(10e18) : -int256(10e18));
        assertEq(short ? creatorClosed : -creatorClosed, 1);
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
