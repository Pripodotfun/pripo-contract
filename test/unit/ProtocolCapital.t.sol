// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InsuranceBackstop} from "../../src/InsuranceBackstop.sol";
import {MarginVault} from "../../src/MarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {HookUSDC, MockUSDC} from "../helpers/MockUSDC.sol";
import {TerminalMarketStub} from "../helpers/TerminalMarketStub.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test} from "forge-std/Test.sol";

contract ProtocolCapitalTest is Test {
    MarginVault internal vault;
    MockUSDC internal usdc;
    InsuranceBackstop internal backstop;
    address internal alice = address(0xa11ce);
    address internal sponsor = address(0x5a);
    address internal treasury = address(0x7);
    address[] internal markets;
    uint64 internal constant RATE = uint64(uint256(0.005e18) / 12_000);

    function setUp() public {
        usdc = new MockUSDC();
        vault = _vault(usdc);
        backstop = new InsuranceBackstop(address(vault));
        vault.setBackstopController(backstop);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.fundProtocolReserve(10_000e6);
        _deposit(alice, 40_000e6);
        _deposit(sponsor, 20_000e6);
        _newMarket();
        _newMarket();
    }

    function testAdmissionRetiresFundingBudgetButKeepsFixedFundedFloorAndTerminalGuard() public {
        assertEq(vault.reserveFloor(), 10_000e18);
        for (uint256 i; i < 11; ++i) {
            address m = i < 2 ? markets[i] : _newMarket();
            vm.prank(m);
            vault.admitMarket(25_000e18, RATE);
            assertEq(vault.reserveBudget(m), 0);
            assertTrue(vault.marketAdmitted(m));
        }
        assertEq(vault.aggregateReserveBudget(), 0);
        assertEq(vault.reserveFloor(), 10_000e18);
        TerminalMarketStub(markets[0]).setState(T.Status.Paused, 0, 0);
        assertEq(vault.reserveFloor(), 10_000e18);
        _finish(markets[0], 0);
        vm.prank(markets[0]);
        vm.expectRevert(E.InvalidConfiguration.selector);
        vault.admitMarket(25_000e18, RATE);
        vm.prank(markets[1]);
        vm.expectRevert(E.InvalidConfiguration.selector);
        vault.admitMarket(1, 1);
        _assertCash();
    }

    function testZeroFundingCapCanBeAdmittedOnlyOnce() public {
        vm.prank(markets[0]);
        vault.admitMarket(25_000e18, 0);
        vault.requireOpenAllowed(markets[0]);
        assertEq(vault.reserveBudget(markets[0]), 0);
        vm.prank(markets[0]);
        vm.expectRevert(E.InvalidConfiguration.selector);
        vault.admitMarket(25_000e18, RATE);
    }

    function testTerminalWaterfallUsesOnlyLocalFeesThenUncappedBackstopReserveAndDeficit() public {
        address m = markets[0];
        _fees(m, 300e18, 200e18, 100e18);
        _fees(markets[1], 500e18, 700e18, 900e18);
        vm.prank(sponsor);
        vault.fundBackstop(1_000e18);
        assertEq(backstop.capacity(m), 100e18);
        _finish(m, 11_650e18);
        T.Ledger memory l = vault.ledger(m);
        assertEq(l.insurance + l.creatorOwed + l.protocolOwed, 0);
        assertEq(vault.backstopBalance(), 0);
        assertEq(vault.protocolReserve(), 0);
        assertEq(vault.deficit(m), 50e18);
        assertEq(vault.totalDeficit(), 50e18);
        assertEq(vault.locked(alice, m), 0);
        l = vault.ledger(markets[1]);
        assertEq(l.insurance, 900e18);
        assertEq(l.creatorOwed, 700e18);
        assertEq(l.protocolOwed, 500e18);
        assertEq(vault.freeBalance(alice), 37_300e18);
        (, bool initialized,,) = backstop.windows(m);
        assertFalse(initialized, "terminal coverage must not use or reset live window");
        _assertCash();
    }

    function testFuzzTerminalSourceBoundaries(uint96 rawDebt) public {
        uint256 debt = bound(rawDebt, 0, 12_000e18);
        address m = markets[0];
        _fees(m, 300e18, 200e18, 100e18);
        vm.prank(sponsor);
        vault.fundBackstop(1_000e18);
        _finish(m, debt);
        T.Ledger memory l = vault.ledger(m);
        assertEq(l.insurance, 100e18 - _used(debt, 0, 100e18));
        assertEq(l.creatorOwed, 200e18 - _used(debt, 100e18, 200e18));
        assertEq(l.protocolOwed, 300e18 - _used(debt, 300e18, 300e18));
        assertEq(vault.backstopBalance(), 1_000e18 - _used(debt, 600e18, 1_000e18));
        assertEq(vault.protocolReserve(), 10_000e18 - _used(debt, 1_600e18, 10_000e18));
        assertEq(vault.deficit(m), debt > 11_600e18 ? debt - 11_600e18 : 0);
        _assertCash();
    }

    function testTerminalAuthorizationStatusExposureOnceAndDuplicateDebtors() public {
        address m = markets[0];
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = alice;
        vm.expectRevert(E.Unauthorized.selector);
        vault.finalizeSettlement(users);
        for (uint256 i; i < uint256(T.Status.Settled); ++i) {
            TerminalMarketStub(m).setState(T.Status(i), 0, 0);
            vm.prank(m);
            vm.expectRevert(E.InvalidTerminalState.selector);
            vault.finalizeSettlement(users);
        }
        TerminalMarketStub(m).setState(T.Status.Settled, 1, 0);
        vm.prank(m);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.finalizeSettlement(users);
        TerminalMarketStub(m).setState(T.Status.Settled, 0, 1);
        vm.prank(m);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.finalizeSettlement(users);
        TerminalMarketStub(m).setState(T.Status.Settled, 0, 0);
        vm.prank(m);
        vault.settleFunding(alice, 1e18);
        vm.prank(m);
        vault.finalizeSettlement(users);
        assertEq(vault.protocolReserve(), 9_999e18, "duplicate debtor cannot double the loss");
        vm.prank(m);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.finalizeSettlement(users);
        vm.prank(m);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.finalizeSettlement(new address[](257));
        _assertCash();
    }

    function testFeesRepayOldestThenRefillReserveBeforeTreasuryIncludingDust() public {
        address first = markets[0];
        address second = markets[1];
        _finish(first, 10_010e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        _finish(second, 20e18);
        address feeMarket = _newMarket();
        _fees(feeMarket, 10_040e18 + 1, 0, 0);
        vm.expectPartialRevert(E.ProtocolDeficit.selector);
        vault.claimProtocolFees(feeMarket);
        (uint256 repaid, uint256 reserved) = vault.allocateProtocolFees(feeMarket, 1);
        assertEq(repaid, 10e18);
        assertEq(reserved, 0);
        assertEq(vault.deficit(first), 0);
        assertEq(vault.deficit(second), 20e18);
        assertEq(vault.protocolReserve(), 0);
        (repaid, reserved) = vault.allocateProtocolFees(feeMarket, 1);
        assertEq(repaid, 20e18);
        assertEq(reserved, 10_000e18);
        assertEq(vault.totalDeficit(), 0);
        assertEq(vault.claimProtocolFees(feeMarket), 10e18);
        assertEq(usdc.balanceOf(treasury), 10e6);
        assertEq(vault.ledger(feeMarket).protocolOwed, 1);
        assertGe(vault.protocolReserve(), vault.reserveFloor());
        _assertCash();
    }

    function testFeeAllocationCanMakePartialProgressBelowReserveFloor() public {
        _finish(markets[0], 500e18);
        _fees(markets[1], 100e18, 0, 0);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        vault.claimProtocolFees(markets[1]);
        (, uint256 reserved) = vault.allocateProtocolFees(markets[1], 32);
        assertEq(reserved, 100e18);
        assertEq(vault.protocolReserve(), 9_600e18);
        vm.expectPartialRevert(E.ReserveBelowFloor.selector);
        vault.claimProtocolFees(markets[1]);
        _assertCash();
    }

    function testTimestampTiesUseAddressAndTargetedRecapDoesNotDuplicateCash() public {
        address low = markets[0] < markets[1] ? markets[0] : markets[1];
        address high = markets[0] < markets[1] ? markets[1] : markets[0];
        _finish(high, 10_010e18);
        _finish(low, 20e18);
        address fees = _newMarket();
        _fees(fees, 5e18, 0, 0);
        vault.allocateProtocolFees(fees, 32);
        assertEq(vault.deficit(low), 15e18);
        assertEq(vault.deficit(high), 10e18);
        uint256 beforeCash = usdc.balanceOf(address(vault));
        vault.recapitalize(high, 12e6);
        assertEq(usdc.balanceOf(address(vault)), beforeCash + 12e6);
        assertEq(vault.deficit(high), 0);
        assertEq(vault.deficit(low), 13e18);
        assertEq(vault.protocolReserve(), 0, "excess recap must repay other deficits first");
        vm.prank(sponsor);
        vault.contributeToDeficit(low, 3e18);
        assertEq(usdc.balanceOf(address(vault)), beforeCash + 12e6);
        assertEq(vault.deficit(low), 10e18);
        vault.fundProtocolReserve(15e6);
        assertEq(vault.totalDeficit(), 0);
        assertEq(vault.protocolReserve(), 5e18);
        assertEq(vault.freeBalance(address(this)), 0);
        (uint8 status,) = TerminalMarketStub(low).status();
        assertEq(status, uint8(T.Status.Settled));
        _assertCash();
    }

    function testBoundedQueueRetainsUnprocessedFeesAndRejectsOversizedCapitalAtomically() public {
        _finish(markets[0], 10_001e18);
        for (uint256 i; i < 33; ++i) {
            _finish(_newMarket(), 1e18);
        }
        uint256 cash = usdc.balanceOf(address(vault));
        vm.expectRevert(E.AllocationLimit.selector);
        vault.fundProtocolReserve(35e6);
        assertEq(usdc.balanceOf(address(vault)), cash);
        assertEq(vault.totalDeficit(), 34e18);
        _fees(markets[1], 35e18, 0, 0);
        (uint256 repaid, uint256 reserved) = vault.allocateProtocolFees(markets[1], 32);
        assertEq(repaid, 32e18);
        assertEq(reserved, 0);
        assertEq(vault.ledger(markets[1]).protocolOwed, 3e18);
        (repaid, reserved) = vault.allocateProtocolFees(markets[1], 32);
        assertEq(repaid, 2e18);
        assertEq(reserved, 1e18);
        _assertCash();
    }

    function testClearedQueueEntriesArePrunedWithinBudgetEvenWithNoFees() public {
        _finish(markets[0], 10_001e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        _finish(markets[1], 1e18);
        vault.recapitalize(markets[0], 1e6);
        (address head, uint256 entries) = vault.deficitQueueHead();
        assertEq(head, markets[0]);
        assertEq(entries, 2);
        vault.allocateProtocolFees(markets[0], 1);
        (head, entries) = vault.deficitQueueHead();
        assertEq(head, markets[1]);
        assertEq(entries, 1);
        vault.recapitalize(markets[1], 2e6);
        assertEq(vault.totalDeficit(), 0);
        assertEq(vault.protocolReserve(), 1e18);
        _assertCash();
    }

    function testFeeDustRepaysDeficitAndRecapExcessBecomesReserve() public {
        _finish(markets[0], 10_000e18 + 3);
        _fees(markets[1], 1, 0, 0);
        vault.allocateProtocolFees(markets[1], 1);
        assertEq(vault.deficit(markets[0]), 2);
        vault.recapitalize(markets[0], 1);
        assertEq(vault.protocolReserve(), 1e12 - 2);
        _assertCash();
    }

    function testContributionAuthorizationBoundsCapExceptionAndUpgradeStorage() public {
        vm.expectRevert(E.Unauthorized.selector);
        vault.admitMarket(1, RATE);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.fundProtocolReserve(0);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.recapitalize(markets[0], 1);
        vm.expectRevert(E.InvalidTerminalState.selector);
        vault.contributeToDeficit(markets[0], 1);
        vm.expectRevert(E.AllocationLimit.selector);
        vault.allocateProtocolFees(markets[0], 0);
        vm.expectRevert(E.AllocationLimit.selector);
        vault.allocateProtocolFees(markets[0], 33);
        vm.expectRevert(E.Unauthorized.selector);
        vault.allocateProtocolFees(alice, 1);
        _finish(markets[0], 10_010e18);
        vm.prank(markets[1]);
        vm.expectPartialRevert(E.ProtocolDeficit.selector);
        vault.admitMarket(25_000e18, RATE);
        MarginVault next = new MarginVault();
        vault.scheduleUpgrade(address(next), keccak256(""));
        vm.warp(vault.upgradeReadyAt());
        vault.upgradeToAndCall(address(next), "");
        assertEq(vault.deficit(markets[0]), 10e18);
        assertEq(vault.totalDeficit(), 10e18);
        assertTrue(vault.terminalFinalized(markets[0]));
        vault.fundProtocolReserve(100_000e6);
        assertEq(vault.protocolReserve(), 99_990e18);
        vm.prank(alice);
        vm.expectRevert(E.DepositCapExceeded.selector);
        vault.deposit(1);
        _assertCash();
    }

    function testTransferTaxCapitalRevertsWithoutReserveOrDeficitChanges() public {
        HookUSDC taxed = new HookUSDC();
        MarginVault target = _vault(taxed);
        taxed.mint(address(this), 10e6);
        taxed.approve(address(target), 10e6);
        taxed.configure(address(target), "", true);
        vm.expectRevert(E.UnsupportedToken.selector);
        target.fundProtocolReserve(10e6);
        assertEq(target.protocolReserve(), 0);
        assertEq(taxed.balanceOf(address(this)), 10e6);
    }

    function testCapitalTransferCallbacksCannotReenterFundingOrTerminalCoverage() public {
        HookUSDC hooked = new HookUSDC();
        MarginVault target = _vault(hooked);
        hooked.mint(address(this), 20_000e6);
        hooked.approve(address(target), type(uint256).max);
        hooked.configureIncomingHook(true);
        hooked.configure(address(target), abi.encodeCall(MarginVault.fundProtocolReserve, (1)), false);
        target.fundProtocolReserve(10_000e6);
        assertFalse(hooked.hookSucceeded());
        assertEq(hooked.hookResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        hooked.configure(address(target), abi.encodeCall(MarginVault.finalizeSettlement, (new address[](0))), false);
        target.fundProtocolReserve(10_000e6);
        assertFalse(hooked.hookSucceeded());
        assertEq(hooked.hookResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(target.protocolReserve(), 20_000e18);
        assertEq(hooked.balanceOf(address(target)), 20_000e6);
    }

    function _vault(MockUSDC token) internal returns (MarginVault) {
        return MarginVault(
            address(
                new ERC1967Proxy(
                    address(new MarginVault()),
                    abi.encodeCall(MarginVault.initialize, (address(token), address(this), address(this), treasury))
                )
            )
        );
    }

    function _newMarket() internal returns (address m) {
        m = address(new TerminalMarketStub());
        vault.registerMarket(m, sponsor);
        markets.push(m);
    }

    function _deposit(address who, uint256 raw) internal {
        usdc.mint(who, raw);
        vm.startPrank(who);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(raw);
        vm.stopPrank();
    }

    function _fees(address market, uint256 protocol, uint256 creator, uint256 insurance) internal {
        vm.prank(market);
        vault.chargeFee(alice, T.FeeBreakdown(protocol + creator + insurance, protocol, creator, insurance, 0), false);
    }

    function _finish(address market, uint256 debt) internal {
        vm.prank(market);
        vault.settleFunding(alice, int256(debt));
        TerminalMarketStub(market).setState(T.Status.Settled, 0, 0);
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(market);
        vault.finalizeSettlement(users);
    }

    function _used(uint256 debt, uint256 before, uint256 available) internal pure returns (uint256) {
        if (debt <= before) return 0;
        return debt - before < available ? debt - before : available;
    }

    function _assertCash() internal view {
        int256 sum = int256(
            vault.freeBalance(alice) + vault.freeBalance(sponsor) + vault.protocolReserve() + vault.backstopBalance()
        );
        uint256 deficits;
        for (uint256 i; i < markets.length; ++i) {
            address m = markets[i];
            T.Ledger memory l = vault.ledger(m);
            sum += int256(l.protocolOwed + l.creatorOwed + l.insurance + l.skewPool) + l.clearing + l.fundingPool
            + vault.locked(alice, m) + vault.locked(sponsor, m) - int256(vault.deficit(m));
            deficits += vault.deficit(m);
            if (vault.deficit(m) != 0) {
                (uint8 state,) = TerminalMarketStub(m).status();
                assertEq(state, uint8(T.Status.Settled));
            }
        }
        assertEq(deficits, vault.totalDeficit());
        assertEq(sum, int256(usdc.balanceOf(address(vault)) * 1e12), "capital cash equality");
    }
}
