// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "../../src/Market.sol";
import {IMarginVault} from "../../src/interfaces/IMarginVault.sol";
import {IPripoErrors as E} from "../../src/interfaces/IPripoErrors.sol";
import {FundingMath} from "../../src/libraries/FundingMath.sol";
import {PripoTypes as T} from "../../src/types/PripoTypes.sol";
import {MarketFixture} from "../helpers/MarketFixture.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract MarketTradingTest is MarketFixture {
    function setUp() public {
        _setup(false);
    }

    function testOpenQuoteIncreasePartialCloseAndFinalDust() public {
        (uint256 average, uint256 fee, uint256 margin, uint256 mark) = market.quoteOpenFor(alice, 7e18 + 123);
        uint256 free = vault.freeBalance(alice);
        vm.prank(alice);
        market.open(7e18 + 123, average, "");
        assertEq(free - vault.freeBalance(alice), margin + fee);
        assertEq(market.markPrice(), mark);
        assertEq(market.position(alice).margin, margin);
        _assertCash();
        _open(alice, 3e18);
        uint256 entry = market.position(alice).entryCost;
        _close(alice, 0.333333333333333333e18);
        assertLt(market.position(alice).entryCost, entry);
        _assertCash();
        _close(alice, 1e18);
        T.Position memory p = market.position(alice);
        assertEq(p.size, 0);
        assertEq(p.entryCost, 0);
        assertEq(p.margin, 0);
        assertEq(p.lastFundingIndex, 0);
        assertEq(vault.ledger(address(market)).clearing, 0);
        _assertCash();
    }

    function testWinnerCanCloseAndWithdrawBeforeOtherTrader() public {
        _open(alice, 9e18);
        _open(bob, 9e18);
        (,, int256 profit,) = market.quoteClose(alice, 1e18);
        assertGt(profit, 0);
        _close(alice, 1e18);
        assertEq(vault.ledger(address(market)).clearing, -profit);
        uint256 withdrawal = vault.freeBalance(alice) / 1e12;
        vm.prank(alice);
        vault.withdraw(withdrawal);
        _assertCash();
        _close(bob, 1e18);
        _assertCash();
        assertEq(vault.ledger(address(market)).clearing, 0);
    }

    function testReceiverFirstFundingAndSurplusSweep() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 12_000);
        (,,, int256 receiverOwed) = market.quoteClose(bob, 1e18);
        assertLt(receiverOwed, 0);
        _close(bob, 1e18);
        assertEq(vault.ledger(address(market)).fundingPool, receiverOwed);
        market.sweepFundingSurplus();
        _assertFunding();
        _close(alice, 1e18);
        market.sweepFundingSurplus();
        assertEq(vault.ledger(address(market)).fundingPool, 0);
        _assertCash();
    }

    function testFundingDebtSurvivesUnsignedPositionAndClosesAgainstInsurance() public {
        _open(alice, 10e18);
        _open(bob, -1e18);
        vm.roll(block.number + 3_000_000);
        vm.prank(alice);
        market.addMargin(1);
        assertEq(market.position(alice).margin, 0);
        assertGt(market.positionDebt(alice), 0);
        (, bool liquidatable) = market.health(alice);
        assertTrue(liquidatable);
        _assertFunding();
        _assertCash();
        uint256 insuranceBefore = vault.ledger(address(market)).insurance;
        _close(alice, 1e18);
        assertLt(vault.ledger(address(market)).insurance, insuranceBefore);
        assertEq(market.positionDebt(alice), 0);
        _close(bob, 1e18);
        market.sweepFundingSurplus();
        _assertCash();
    }

    function testRemoveMarginCannotSpendInitialCollateral() public {
        _open(alice, 10e18);
        vm.prank(alice);
        vm.expectPartialRevert(E.InsufficientMargin.selector);
        market.removeMargin(1);
        vm.prank(alice);
        market.addMargin(100e18);
        vm.prank(alice);
        market.removeMargin(50e18);
        _assertCash();
    }

    function testCapsSlippageAndOppositeSideRejectAtomically() public {
        vm.prank(alice);
        vm.expectPartialRevert(E.OICapExceeded.selector);
        market.open(21e18, type(uint256).max, "");
        vm.prank(alice);
        vm.expectPartialRevert(E.Slippage.selector);
        market.open(1e18, 1, "");
        assertEq(market.longSize(), 0);
        _open(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(E.PositionExists.selector);
        market.open(-1e18, 0, "");
        _assertCash();
    }

    function testOperatorProofClosePermissionAndAtomicConsumption() public {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(market)))));
        T.OperatorPolicy memory p = T.OperatorPolicy(uint64(block.number + 100), 1_500e18, 2_500e18, 0, leaf, false);
        vm.prank(alice);
        vault.setOperator(carol, p);
        vm.prank(carol);
        market.openFor(alice, 10e18, type(uint256).max, "", new bytes32[](0));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 2));
        market.closeFor(alice, 1e18, 0, "");
        (,,, uint128 used,,) = vault.operators(alice, carol);
        assertEq(used, market.position(alice).entryCost);
        p.canClose = true;
        vm.prank(alice);
        vault.setOperator(carol, p);
        vm.prank(carol);
        market.closeFor(alice, 1e18, 0, "", new bytes32[](0));
        assertEq(market.position(alice).size, 0);
        vm.prank(alice);
        vault.revokeOperator(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(E.PolicyViolation.selector, 1));
        market.openFor(alice, 1e18, type(uint256).max, "");
        assertEq(market.position(alice).size, 0);
        _assertCash();
    }

    function testReferralCreatorClaimsAndSkewDiscount() public {
        vm.prank(creator);
        vault.registerReferralCode("CREATOR");
        vm.prank(alice);
        vault.setReferrer("CREATOR");
        _open(alice, 10e18);
        (, uint256 discounted,,) = market.quoteOpenFor(bob, -1e18);
        _open(bob, -1e18);
        assertLt(discounted, 0.08e18);
        assertGt(vault.referralOwed(creator), 0);
        vm.prank(creator);
        market.claimCreatorFees();
        vm.prank(creator);
        vault.claimReferral();
        vault.claimProtocolFees(address(market));
        _assertCash();
    }

    function testGuardianPauseCannotBeBypassedAndDoesNotBlockExit() public {
        _open(alice, 1e18);
        vm.prank(guardian);
        market.pauseOpens();
        market.remark();
        vm.prank(bob);
        vm.expectRevert(E.MarketNotActive.selector);
        market.open(1e18, type(uint256).max, "");
        _close(alice, 1e18);
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector);
        market.resumeOpens();
        market.resumeOpens();
        _open(bob, 1e18);
        _assertCash();
    }

    function testReseedOnlyAtZeroOiAndCreatorTransfer() public {
        _open(alice, 1e18);
        vm.prank(creator);
        vm.expectRevert(E.PositionExists.selector);
        market.reseed(4_000_000e18);
        _close(alice, 1e18);
        vm.prank(creator);
        market.reseed(4_000_000e18);
        _assertCash();
        assertEq(market.ammState().baseAtSeed, 40_000e18);
        vm.prank(creator);
        market.transferCreator(bob);
        assertEq(vault.creatorOf(address(market)), bob);
        vm.prank(creator);
        vm.expectRevert(E.Unauthorized.selector);
        market.claimCreatorFees();
    }

    function testCloneAndImplementationCannotReinitialize() public {
        T.MarketConfig memory c = _config(false);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        market.initialize(IMarginVault(address(vault)), 0, false, c, 100e18, 2_000_000e18);
        Market implementation = new Market();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(IMarginVault(address(vault)), 0, false, c, 100e18, 2_000_000e18);
    }

    function testTwoMarketsKeepCollateralAndInsuranceIsolated() public {
        Market second = _newMarket(false);
        _open(alice, 5e18);
        uint256 firstMargin = market.position(alice).margin;
        uint256 firstInsurance = vault.ledger(address(market)).insurance;
        vm.prank(alice);
        second.open(-5e18, 0, "");
        vm.prank(alice);
        second.close(1e18, type(uint256).max, "");
        assertEq(market.position(alice).margin, firstMargin);
        assertEq(vault.ledger(address(market)).insurance, firstInsurance);
        assertEq(vault.locked(alice, address(second)), 0);
        T.Ledger memory first = vault.ledger(address(market));
        T.Ledger memory other = vault.ledger(address(second));
        int256 sum = int256(
            vault.freeBalance(alice) + vault.freeBalance(bob) + vault.freeBalance(carol) + vault.freeBalance(creator)
                + vault.protocolReserve()
        );
        sum += vault.locked(alice, address(market));
        sum += int256(
            first.insurance + first.protocolOwed + first.creatorOwed + other.insurance + other.protocolOwed
                + other.creatorOwed
        );
        sum += first.clearing + first.fundingPool + other.clearing + other.fundingPool;
        assertEq(sum, int256(usdc.balanceOf(address(vault)) * 1e12));
    }

    function _assertFunding() internal view {
        T.FundingState memory f = market.fundingState();
        FundingMath.surplus(f, vault.ledger(address(market)).fundingPool, market.longSize(), market.shortSize());
    }
}
