// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InsuranceBackstop} from "../../src/InsuranceBackstop.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract AdlReservationTest is Test {
    MarginVault internal vault;
    InsuranceBackstop internal backstop;
    MockUSDC internal token;
    address internal first;
    address internal second;
    address internal loser = address(0xa);
    address internal winner = address(0xb);

    function setUp() public {
        token = new MockUSDC();
        vault = MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(
                        MarginVault.initialize, (address(token), address(this), address(0x123), address(0x456))
                    )
                )
            )
        );
        backstop = new InsuranceBackstop(address(vault));
        vault.setBackstopController(backstop);
        first = address(new TerminalMarketStub());
        second = address(new TerminalMarketStub());
        vault.registerMarket(first, address(this));
        vault.registerMarket(second, address(this));
        token.mint(address(this), 40_000e6);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(20_000e6);
    }

    function testReservationMovesCashAndCommitsBackstopWindowOnce() public {
        vault.fundInsurance(first, 20e18);
        vault.fundBackstop(1_000e18);
        vm.prank(first);
        (uint256 coverage, uint256 fromC, uint256 fromReserve) = vault.reserveAdl(loser, 128);
        assertEq(coverage, 120e18);
        assertEq(fromC, 128);
        assertEq(fromReserve, 0);
        assertEq(vault.ledger(first).insurance, 0);
        assertEq(vault.backstopBalance(), 900e18);
        assertEq(backstop.capacity(first), 0);
        assertEq(vault.locked(loser, first), 0);
        assertEq(vault.adlReserved(first, loser), coverage);
        vm.prank(first);
        vm.expectRevert(E.AdlAlreadyPending.selector);
        vault.reserveAdl(loser, 128);
        vm.prank(first);
        vault.settleFunding(winner, 200e18);
        vm.prank(first);
        (uint256 local, uint256 global, uint256 unpaid) = vault.coverBadDebt(winner);
        assertEq(local + global, 0);
        assertEq(unpaid, 200e18);
        assertEq(vault.adlReserved(first, loser), coverage);
        vm.prank(first);
        vault.consumeAdlCoverage(loser, 7e18);
        vm.prank(first);
        vault.releaseAdlReservation(loser);
        assertEq(backstop.capacity(first), 0);
        assertEq(vault.ledger(first).insurance, 113e18);
        assertEq(vault.locked(loser, first), 7e18);
        _cash();
    }

    function testReserveOnlyFundsAllowanceAndUnusedPartReturnsToReserve() public {
        vault.fundProtocolReserve(10_000e6);
        vm.prank(first);
        vault.admitMarket(25_000e18, 0);
        vault.fundInsurance(first, 10);
        vm.prank(first);
        (uint256 coverage, uint256 fromC, uint256 fromReserve) = vault.reserveAdl(loser, 128);
        assertEq(coverage, 10);
        assertEq(fromC, 10);
        assertEq(fromReserve, 118);
        assertEq(vault.adlReservation(first, loser).lossCoverage, 0);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        vault.requireOpenAllowed(first);
        for (uint256 i; i < 11; ++i) {
            vm.prank(first);
            assertTrue(vault.payAdlRounding(loser, winner));
        }
        assertEq(vault.freeBalance(winner), 11);
        vm.prank(first);
        assertEq(vault.releaseAdlReservation(loser), 117);
        assertEq(vault.protocolReserve(), 10_000e18 - 1);
        assertEq(vault.ledger(first).insurance, 0);
        _cash();
    }

    function testReliefRestoresOnlyConsumedCoverageAndNeverCreditsFree() public {
        vault.fundInsurance(first, 1_000);
        vm.prank(first);
        vault.reserveAdl(loser, 128);
        vm.prank(first);
        vault.consumeAdlCoverage(loser, 400);
        vm.prank(first);
        vault.restoreAdlCoverage(loser, 100);
        assertEq(vault.locked(loser, first), 300);
        assertEq(vault.freeBalance(loser), 0);
        assertEq(vault.adlReservation(first, loser).consumedCoverage, 300);
        assertEq(vault.adlReservation(first, loser).lossCoverage, 572);
        vm.prank(first);
        vm.expectRevert(E.AccountingInvariant.selector);
        vault.restoreAdlCoverage(loser, 301);
        _cash();
    }

    function testAddedMarginReplacementCannotTouchAllowanceOrConsumedCoverage() public {
        vault.fundInsurance(first, 1_000);
        vm.prank(first);
        vault.reserveAdl(loser, 128);
        vm.prank(first);
        vault.consumeAdlCoverage(loser, 400);
        vm.prank(first);
        vault.returnAdlCoverage(loser, 472);
        T.AdlReservation memory r = vault.adlReservation(first, loser);
        assertEq(r.lossCoverage, 0);
        assertEq(r.allowanceFromCoverage, 128);
        vm.prank(first);
        vm.expectRevert(E.AccountingInvariant.selector);
        vault.returnAdlCoverage(loser, 1);
        vm.prank(first);
        vm.expectRevert(E.AccountingInvariant.selector);
        vault.consumeAdlCoverage(loser, 1);
        assertEq(vault.locked(loser, first), 400);
        assertEq(vault.ledger(first).insurance, 472);
        _cash();
    }

    function testFuzzAllowanceHasOneWeiCostAndCannotUseLossCoverage(uint16 coverageSeed, uint8 capSeed) public {
        uint256 coverage = bound(coverageSeed, 0, 256);
        uint256 cap = bound(capSeed, 1, 128);
        if (coverage != 0) vault.fundInsurance(first, coverage);
        vm.prank(first);
        vault.reserveAdl(loser, cap);
        uint256 funded = Math.min(cap, coverage);
        for (uint256 i; i < cap + 1; ++i) {
            vm.prank(first);
            assertEq(vault.payAdlRounding(loser, winner), i < funded);
        }
        assertEq(vault.freeBalance(winner), funded);
        assertEq(vault.adlReservation(first, loser).lossCoverage, coverage - funded);
        assertEq(vault.adlReserved(first, loser), coverage - funded);
        _cash();
    }

    function testTerminalMarketCannotConsumeAnotherMarketsReservation() public {
        vault.fundInsurance(first, 50e18);
        vm.prank(first);
        vault.reserveAdl(loser, 128);
        vm.prank(second);
        vault.settleFunding(loser, 100e18);
        vm.prank(second);
        vault.settleFunding(winner, -100e18);
        vm.prank(second);
        vault.release(winner, 100e18);
        TerminalMarketStub(second).setState(T.Status.Settled, 0, 0);
        address[] memory debtors = new address[](1);
        debtors[0] = loser;
        vm.prank(second);
        vault.finalizeSettlement(debtors);
        assertEq(vault.adlReserved(first, loser), 50e18);
        assertEq(vault.adlReservedTotal(first), 50e18);
        assertEq(vault.deficit(second), 100e18);
        _cash();
    }

    function testTerminalFinalizationRequiresEvenZeroCashReservationToBeReleased() public {
        vm.prank(first);
        vault.reserveAdl(loser, 128);
        assertEq(vault.adlReservedTotal(first), 0);
        TerminalMarketStub(first).setState(T.Status.Settled, 0, 0);
        vm.prank(first);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.finalizeSettlement(new address[](0));
        vm.prank(first);
        vault.releaseAdlReservation(loser);
        vm.prank(first);
        vault.finalizeSettlement(new address[](0));
        assertEq(vault.adlReservationCount(first), 0);
    }

    function testReservationAuthorizationAndMarketUserIsolation() public {
        vm.expectRevert(E.Unauthorized.selector);
        vault.reserveAdl(loser, 128);
        vault.fundInsurance(first, 1_000);
        vm.prank(first);
        vault.reserveAdl(loser, 128);
        vm.prank(second);
        vm.expectRevert(E.NoPendingAdl.selector);
        vault.consumeAdlCoverage(loser, 1);
        vm.prank(first);
        vm.expectRevert(E.NoPendingAdl.selector);
        vault.consumeAdlCoverage(winner, 1);
        vm.expectRevert(E.Unauthorized.selector);
        vault.returnAdlCoverage(loser, 1);
        vm.expectRevert(E.Unauthorized.selector);
        vault.payAdlRounding(loser, winner);
        vm.expectRevert(E.Unauthorized.selector);
        vault.releaseAdlReservation(loser);
        vm.prank(first);
        vault.releaseAdlReservation(loser);
        vm.prank(first);
        vm.expectRevert(E.NoPendingAdl.selector);
        vault.releaseAdlReservation(loser);
        _cash();
    }

    function _cash() internal view {
        int256 sum = int256(
            vault.freeBalance(address(this)) + vault.freeBalance(loser) + vault.freeBalance(winner)
                + vault.protocolReserve() + vault.backstopBalance()
        );
        address[2] memory markets = [first, second];
        for (uint256 i; i < markets.length; ++i) {
            address m = markets[i];
            T.Ledger memory l = vault.ledger(m);
            sum += int256(l.insurance + l.protocolOwed + l.creatorOwed + l.skewPool);
            sum += l.clearing + l.fundingPool + vault.locked(loser, m) + vault.locked(winner, m);
            uint256 reserved = vault.adlReserved(m, loser) + vault.adlReserved(m, winner);
            assertEq(vault.adlReservedTotal(m), reserved);
            sum += int256(reserved);
        }
        sum -= int256(vault.totalDeficit());
        assertEq(sum, int256(token.balanceOf(address(vault)) * 1e12));
    }
}
